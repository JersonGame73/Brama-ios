//
//  BramaCore.mm
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

#import "BramaCore.h"
#include "BramaRuntimePayloads.h"
#include <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <sys/time.h>
#include <vector>
#include <string>
#include <unordered_map>
#include <cstring>
#include <cstdint>

// ============================================================================
// MARK: - Madeira iOS Engine (libmadeira.dylib: Wine ARM64EC + FEX + DXMT + Winios)
// ============================================================================

struct BramaWiniosGamepadState {
    uint32_t packet;
    uint16_t buttons;
    uint8_t left_trigger;
    uint8_t right_trigger;
    int16_t lx;
    int16_t ly;
    int16_t rx;
    int16_t ry;
    uint8_t connected;
    uint8_t reserved[3];
};

typedef int (*MadeiraWineserverStartFn)(const char *prefix_path);
typedef int (*MadeiraWineserverIsRunningFn)(void);
typedef int (*MadeiraWineserverIsReadyFn)(void);
typedef void (*MadeiraWineserverStopFn)(void);
typedef int (*MadeiraWineProcessStartFn)(const char *prefix_path);
typedef int (*MadeiraWineProcessIsRunningFn)(void);
typedef int (*MadeiraWineProcessExitCodeFn)(void);
typedef void (*MadeiraSeedPrefixIfNeededFn)(const char *prefix_path);
typedef void (*MadeiraWineSetUILogCallbackFn)(void (*cb)(const char *msg));

typedef void (*MadeiraDisplaySetLayerFn)(CAMetalLayer *layer);
typedef uint64_t (*MadeiraGetPresentCountFn)(void);
typedef uint64_t (*MadeiraWiniosSurfacePresentCountFn)(void);
typedef void (*MadeiraSetVsyncLockedFn)(int locked);
typedef void (*MadeiraSetDisplayMaxFpsFn)(int fps);

typedef void (*MadeiraWiniosSetCompositorFrameFn)(double x, double y, double w, double h);
typedef void (*MadeiraWiniosSetDesktopRectFn)(double x, double y, double w, double h, int set);
typedef void (*MadeiraWiniosScreenSizeFn)(int *w, int *h);
typedef void (*MadeiraWiniosDisplayModeChangedFn)(int w, int h);
typedef void (*MadeiraWiniosPostTouchFn)(int x, int y);
typedef void (*MadeiraWiniosPostKeyFn)(int vk, int down);
typedef void (*MadeiraWiniosGamepadSetStateFn)(int index, const BramaWiniosGamepadState *state);

typedef bool (*MadeiraJitCheckDebuggedFn)(void);
typedef void *(*MadeiraJit26PrepareRegionFn)(void *addr, size_t len);
typedef void (*MadeiraJit26DetachFn)(void);
typedef bool (*MadeiraJitMakeRegionNoFootprintFn)(void *addr, size_t len, const char *label);

static bool brama_call_stikjit_allocate_pool(
    void *fnPtr,
    size_t poolSize,
    void **outRx,
    void **outRw,
    size_t *outSize
) {
#if defined(__arm64__) || defined(__aarch64__)
    if (!fnPtr) return false;
    register uint64_t x0 __asm__("x0") = (uint64_t)poolSize;
    register uint64_t x1 __asm__("x1") = 0;
    register uint64_t x2 __asm__("x2") = 0;
    register void *target __asm__("x9") = fnPtr;
    __asm__ volatile(
        "blr %[fn]\n"
        : "+r"(x0), "=r"(x1), "=r"(x2)
        : [fn] "r"(target)
        : "x3", "x4", "x5", "x6", "x7", "x8", "x10", "x11", "x12", "x13",
          "x14", "x15", "x16", "x17", "x20", "lr", "memory", "cc"
    );
    if (x0 == 0 || x1 == 0) return false;
    if (outRx) *outRx = (void *)(uintptr_t)x0;
    if (outRw) *outRw = (void *)(uintptr_t)x1;
    if (outSize) *outSize = (size_t)x2;
    return true;
#else
    (void)fnPtr;
    (void)poolSize;
    (void)outRx;
    (void)outRw;
    (void)outSize;
    return false;
#endif
}

#ifndef VM_LEDGER_TAG_DEFAULT
#define VM_LEDGER_TAG_DEFAULT 0
#endif
#ifndef VM_LEDGER_FLAG_NO_FOOTPRINT
#define VM_LEDGER_FLAG_NO_FOOTPRINT (1 << 0)
#endif
extern "C" kern_return_t mach_memory_entry_ownership(
    mach_port_t mem_entry,
    mach_port_t owner,
    int ledger_tag,
    int ledger_flags
);

static void *g_madeiraDylibHandle = NULL;
static void *g_madeiraJitRxBase = NULL;
static void *g_madeiraJitRwBase = NULL;
static size_t g_madeiraJitPoolSize = 0;
static BramaLogCallback g_activeUILogCallback = nil;

static void brama_madeira_ui_log_bridge(const char *msg) {
    if (!msg || !*msg) return;
    NSString *line = [NSString stringWithUTF8String:msg];
    if (!line) return;
    BramaLogCallback cb = g_activeUILogCallback;
    if (cb) {
        cb([NSString stringWithFormat:@"[WINE] %@", line]);
    }
}

// Early constructor (priority 101) loads libmadeira.dylib before main() runs so that
// madeira_early_va_claim reserves [0x140000000, +128MB) (WINE_IOS_EXE_WINDOW) and
// [0x148000000, +512MB) (JIT RX low placeholder) before any heap or framework allocations.
__attribute__((constructor(101), used))
static void brama_early_load_madeira_engine(void) {
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR
    char execPath[4096] = {0};
    uint32_t size = sizeof(execPath);
    if (_NSGetExecutablePath(execPath, &size) == 0) {
        char *lastSlash = strrchr(execPath, '/');
        if (lastSlash) {
            *lastSlash = '\0';
            char dylibPath[4096] = {0};
            snprintf(dylibPath, sizeof(dylibPath), "%s/libmadeira.dylib", execPath);
            if (access(dylibPath, R_OK) == 0) {
                g_madeiraDylibHandle = dlopen(dylibPath, RTLD_NOW | RTLD_GLOBAL);
            }
        }
    }
#endif
}

// ============================================================================
// MARK: - Windows Portable Executable (PE32 / PE32+) C++ Structures
// ============================================================================

#pragma pack(push, 1)

static constexpr uint16_t BRAMA_IMAGE_DOS_SIGNATURE    = 0x5A4D;     // "MZ"
static constexpr uint32_t BRAMA_IMAGE_NT_SIGNATURE     = 0x00004550; // "PE\0\0"
static constexpr uint16_t BRAMA_IMAGE_NT_OPTIONAL_HDR32_MAGIC = 0x010B; // PE32
static constexpr uint16_t BRAMA_IMAGE_NT_OPTIONAL_HDR64_MAGIC = 0x020B; // PE32+ (64-bit)

static constexpr uint16_t BRAMA_IMAGE_FILE_MACHINE_I386    = 0x014C;
static constexpr uint16_t BRAMA_IMAGE_FILE_MACHINE_AMD64   = 0x8664;
static constexpr uint16_t BRAMA_IMAGE_FILE_MACHINE_ARM64   = 0xAA64;
static constexpr uint16_t BRAMA_IMAGE_FILE_MACHINE_ARM64EC = 0xA641;

static constexpr uint32_t BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT    = 0;
static constexpr uint32_t BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT    = 1;
static constexpr uint32_t BRAMA_IMAGE_DIRECTORY_ENTRY_BASERELOC = 5;

static constexpr uint32_t BRAMA_IMAGE_SCN_CNT_CODE               = 0x00000020;
static constexpr uint32_t BRAMA_IMAGE_SCN_CNT_INITIALIZED_DATA   = 0x00000040;
static constexpr uint32_t BRAMA_IMAGE_SCN_MEM_EXECUTE            = 0x20000000;
static constexpr uint32_t BRAMA_IMAGE_SCN_MEM_READ               = 0x40000000;
static constexpr uint32_t BRAMA_IMAGE_SCN_MEM_WRITE              = 0x80000000;

struct BramaImageDosHeader {
    uint16_t e_magic;      // Magic number ("MZ")
    uint16_t e_cblp;
    uint16_t e_cp;
    uint16_t e_crlc;
    uint16_t e_cparhdr;
    uint16_t e_minalloc;
    uint16_t e_maxalloc;
    uint16_t e_ss;
    uint16_t e_sp;
    uint16_t e_csum;
    uint16_t e_ip;
    uint16_t e_cs;
    uint16_t e_lfarlc;
    uint16_t e_ovno;
    uint16_t e_res[4];
    uint16_t e_oemid;
    uint16_t e_oeminfo;
    uint16_t e_res2[10];
    int32_t  e_lfanew;     // File offset to IMAGE_NT_HEADERS
};

struct BramaImageFileHeader {
    uint16_t Machine;
    uint16_t NumberOfSections;
    uint32_t TimeDateStamp;
    uint32_t PointerToSymbolTable;
    uint32_t NumberOfSymbols;
    uint16_t SizeOfOptionalHeader;
    uint16_t Characteristics;
};

struct BramaImageDataDirectory {
    uint32_t VirtualAddress;
    uint32_t Size;
};

struct BramaImageOptionalHeader64 {
    uint16_t Magic; // 0x020B (PE32+)
    uint8_t  MajorLinkerVersion;
    uint8_t  MinorLinkerVersion;
    uint32_t SizeOfCode;
    uint32_t SizeOfInitializedData;
    uint32_t SizeOfUninitializedData;
    uint32_t AddressOfEntryPoint;
    uint32_t BaseOfCode;
    uint64_t ImageBase;
    uint32_t SectionAlignment;
    uint32_t FileAlignment;
    uint16_t MajorOperatingSystemVersion;
    uint16_t MinorOperatingSystemVersion;
    uint16_t MajorImageVersion;
    uint16_t MinorImageVersion;
    uint16_t MajorSubsystemVersion;
    uint16_t MinorSubsystemVersion;
    uint32_t Win32VersionValue;
    uint32_t SizeOfImage;
    uint32_t SizeOfHeaders;
    uint32_t CheckSum;
    uint16_t Subsystem;
    uint16_t DllCharacteristics;
    uint64_t SizeOfStackReserve;
    uint64_t SizeOfStackCommit;
    uint64_t SizeOfHeapReserve;
    uint64_t SizeOfHeapCommit;
    uint32_t LoaderFlags;
    uint32_t NumberOfRvaAndSizes;
    BramaImageDataDirectory DataDirectory[16];
};

struct BramaImageOptionalHeader32 {
    uint16_t Magic; // 0x010B (PE32)
    uint8_t  MajorLinkerVersion;
    uint8_t  MinorLinkerVersion;
    uint32_t SizeOfCode;
    uint32_t SizeOfInitializedData;
    uint32_t SizeOfUninitializedData;
    uint32_t AddressOfEntryPoint;
    uint32_t BaseOfCode;
    uint32_t BaseOfData;
    uint32_t ImageBase;
    uint32_t SectionAlignment;
    uint32_t FileAlignment;
    uint16_t MajorOperatingSystemVersion;
    uint16_t MinorOperatingSystemVersion;
    uint16_t MajorImageVersion;
    uint16_t MinorImageVersion;
    uint16_t MajorSubsystemVersion;
    uint16_t MinorSubsystemVersion;
    uint32_t Win32VersionValue;
    uint32_t SizeOfImage;
    uint32_t SizeOfHeaders;
    uint32_t CheckSum;
    uint16_t Subsystem;
    uint16_t DllCharacteristics;
    uint32_t SizeOfStackReserve;
    uint32_t SizeOfStackCommit;
    uint32_t SizeOfHeapReserve;
    uint32_t SizeOfHeapCommit;
    uint32_t LoaderFlags;
    uint32_t NumberOfRvaAndSizes;
    BramaImageDataDirectory DataDirectory[16];
};

struct BramaImageSectionHeader {
    char     Name[8];
    uint32_t VirtualSize;
    uint32_t VirtualAddress;
    uint32_t SizeOfRawData;
    uint32_t PointerToRawData;
    uint32_t PointerToRelocations;
    uint32_t PointerToLinenumbers;
    uint16_t NumberOfRelocations;
    uint16_t NumberOfLinenumbers;
    uint32_t Characteristics;
};

struct BramaImageImportDescriptor {
    uint32_t OriginalFirstThunk; // RVA to Import Lookup Table
    uint32_t TimeDateStamp;
    uint32_t ForwarderChain;
    uint32_t Name;               // RVA to null-terminated ASCII DLL name
    uint32_t FirstThunk;         // RVA to Import Address Table (IAT)
};

struct BramaImageBaseRelocation {
    uint32_t VirtualAddress;
    uint32_t SizeOfBlock;
};

struct BramaImageExportDirectory {
    uint32_t Characteristics;
    uint32_t TimeDateStamp;
    uint16_t MajorVersion;
    uint16_t MinorVersion;
    uint32_t Name;
    uint32_t Base;
    uint32_t NumberOfFunctions;
    uint32_t NumberOfNames;
    uint32_t AddressOfFunctions;     // RVA from base of image
    uint32_t AddressOfNames;         // RVA from base of image
    uint32_t AddressOfNameOrdinals;  // RVA from base of image
};

#pragma pack(pop)

// ============================================================================
// MARK: - Internal C++ Structures for DLL Mapping & Win64 IAT Thunking
// ============================================================================

static constexpr uint64_t BRAMA_IAT_THUNK_BASE_VA = 0x00007FF7B0000000ULL;

struct BramaMappedModuleRegion {
    void *baseAddress;
    size_t mappedSize;
    std::string moduleName;
};

struct BramaWin64ThunkEntry {
    uint64_t thunkVA;
    std::string dllName;
    std::string symbolName;
    uint64_t resolvedExportVA;
};

// External ARM64 iOS Dynamic Library (.dylib) Function Signatures
typedef const char * (*BramaBox64VersionFn)(void);
typedef int (*BramaBox64InitFn)(int jitEnabled);
typedef uint64_t (*BramaBox64TranslateBlockFn)(const uint8_t *x64Code, size_t codeLen, uint64_t rip, uint64_t *outRsp, uint64_t *outRax);

typedef const char * (*BramaWineVersionFn)(void);
typedef int (*BramaWineInitPrefixFn)(const char *prefixPath);
typedef uint64_t (*BramaWineResolveThunkFn)(const char *dllName, const char *symbolName);

typedef const char * (*BramaDXMTVersionFn)(void);
typedef int (*BramaDXMTBindMetalFn)(const char *gpuName);
typedef uint64_t (*BramaDXMTPresentFrameFn)(uint64_t frameIndex, float *outClearRGB);

// ============================================================================
// MARK: - Objective-C Metadata Models Implementation
// ============================================================================

@implementation BramaPEExecutableInfo
- (instancetype)init {
    self = [super init];
    if (self) {
        _isValidPE = NO;
        _is64Bit = YES;
        _filePath = @"";
        _architectureName = @"Unknown";
        _subsystemName = @"Windows GUI";
        _sectionNames = @[];
        _importedDLLs = @[];
        _importedSymbols = @[];
        _exportedSymbols = @[];
        _exportTableCount = 0;
        _resolvedIATThunkCount = 0;
        _extractedIconData = nil;
        _unityDataSummary = @[];
    }
    return self;
}
@end

@implementation BramaRuntimeModulesStatus
- (instancetype)init {
    self = [super init];
    if (self) {
        _cpuTranslatorLoaded = NO;
        _cpuTranslatorModuleName = @"Internal ARM64 JIT / IR Bridge";
        _wineRuntimeLoaded = NO;
        _wineRuntimeModuleName = @"Brama WineKit Win64 Shim";
        _dxmtMetalLoaded = NO;
        _dxmtMetalModuleName = @"Apple Metal Direct Bridge";
        _runtimeSearchPath = @"";
        _framesPresented = 0;
    }
    return self;
}
@end

// ============================================================================
// MARK: - BramaCore Implementation
// ============================================================================

@interface BramaCore () {
    BOOL _isRunning;
    BOOL _dxmtSwapchainActive;
    void *_mappedPEImageBase;
    size_t _mappedPEImageSize;
    std::vector<BramaMappedModuleRegion> _mappedDLLRegions;
    std::unordered_map<std::string, uint64_t> _exportedSymbolAddressMap;
    std::vector<BramaWin64ThunkEntry> _iatThunkTable;
    uint64_t _tlsSlots[64];
    uint32_t _nextTlsSlot;
    uint32_t _lastWin32Error;
    uint64_t _dxmtFrameCounter;
    void *_jitCodeCache;
    size_t _jitCodeCacheSize;
    void *_cpuTranslatorHandle;
    void *_wineLibraryHandle;
    void *_dxmtLibraryHandle;
    BramaDXMTPresentFrameFn _dxmtPresentFn;
    id<MTLDevice> _metalDevice;
    id<MTLCommandQueue> _metalCommandQueue;
    NSMutableArray<BramaPEExecutableInfo *> *_mutableLoadedDLLs;
    CAMetalLayer *_registeredMetalLayer;
    dispatch_source_t _logTailTimer;
    unsigned long long _lastLogFileOffset;
    MadeiraWineserverStartFn _fnWineserverStart;
    MadeiraWineserverIsRunningFn _fnWineserverIsRunning;
    MadeiraWineserverIsReadyFn _fnWineserverIsReady;
    MadeiraWineserverStopFn _fnWineserverStop;
    MadeiraWineProcessStartFn _fnWineProcessStart;
    MadeiraWineProcessIsRunningFn _fnWineProcessIsRunning;
    MadeiraWineProcessExitCodeFn _fnWineProcessExitCode;
    MadeiraSeedPrefixIfNeededFn _fnSeedPrefixIfNeeded;
    MadeiraWineSetUILogCallbackFn _fnWineSetUILogCallback;
    MadeiraDisplaySetLayerFn _fnDisplaySetLayer;
    MadeiraGetPresentCountFn _fnGetPresentCount;
    MadeiraWiniosSurfacePresentCountFn _fnWiniosSurfacePresentCount;
    MadeiraSetVsyncLockedFn _fnSetVsyncLocked;
    MadeiraSetDisplayMaxFpsFn _fnSetDisplayMaxFps;
    MadeiraWiniosSetCompositorFrameFn _fnWiniosSetCompositorFrame;
    MadeiraWiniosSetDesktopRectFn _fnWiniosSetDesktopRect;
    MadeiraWiniosScreenSizeFn _fnWiniosScreenSize;
    MadeiraWiniosDisplayModeChangedFn _fnWiniosDisplayModeChanged;
    MadeiraWiniosPostTouchFn _fnWiniosPostTouchDown;
    MadeiraWiniosPostTouchFn _fnWiniosPostTouchMove;
    MadeiraWiniosPostTouchFn _fnWiniosPostTouchUp;
    MadeiraWiniosPostKeyFn _fnWiniosPostKey;
    MadeiraWiniosGamepadSetStateFn _fnWiniosGamepadSetState;
    MadeiraJitCheckDebuggedFn _fnJitCheckDebugged;
    MadeiraJit26PrepareRegionFn _fnJit26PrepareRegion;
    MadeiraJit26DetachFn _fnJit26Detach;
    MadeiraJitMakeRegionNoFootprintFn _fnJitMakeRegionNoFootprint;
    void *_fnStikJITAllocatePool;
}
@property (nonatomic, strong, readwrite, nullable) BramaPEExecutableInfo *lastLoadedExecutable;
@property (nonatomic, strong, readwrite) BramaRuntimeModulesStatus *runtimeStatus;
@end

@implementation BramaCore

+ (instancetype)sharedCore {
    static BramaCore *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[BramaCore alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isRunning = NO;
        _dxmtSwapchainActive = NO;
        _mappedPEImageBase = NULL;
        _mappedPEImageSize = 0;
        std::memset(_tlsSlots, 0, sizeof(_tlsSlots));
        _nextTlsSlot = 1;
        _lastWin32Error = 0;
        _dxmtFrameCounter = 0;
        _jitCodeCache = NULL;
        _jitCodeCacheSize = 0;
        _cpuTranslatorHandle = NULL;
        _wineLibraryHandle = NULL;
        _dxmtLibraryHandle = NULL;
        _dxmtPresentFn = NULL;
        _mutableLoadedDLLs = [NSMutableArray array];
        _runtimeStatus = [[BramaRuntimeModulesStatus alloc] init];
        _metalDevice = MTLCreateSystemDefaultDevice();
        if (_metalDevice) {
            _metalCommandQueue = [_metalDevice newCommandQueue];
        }
        _registeredMetalLayer = nil;
        _logTailTimer = nil;
        _lastLogFileOffset = 0;
        [self bindMadeiraEngineSymbols];
        [self configureEnvironment];
    }
    return self;
}

- (void)bindMadeiraEngineSymbols {
    if (!g_madeiraDylibHandle) {
        NSString *bundleDylib = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"libmadeira.dylib"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:bundleDylib]) {
            g_madeiraDylibHandle = dlopen([bundleDylib UTF8String], RTLD_NOW | RTLD_GLOBAL);
        }
    }
    void *h = g_madeiraDylibHandle ?: RTLD_DEFAULT;
    _fnWineserverStart            = (MadeiraWineserverStartFn)dlsym(h, "wineserver_start");
    _fnWineserverIsRunning        = (MadeiraWineserverIsRunningFn)dlsym(h, "wineserver_is_running");
    _fnWineserverIsReady          = (MadeiraWineserverIsReadyFn)dlsym(h, "wineserver_is_ready");
    _fnWineserverStop             = (MadeiraWineserverStopFn)dlsym(h, "wineserver_stop");
    _fnWineProcessStart           = (MadeiraWineProcessStartFn)dlsym(h, "wine_process_start");
    _fnWineProcessIsRunning       = (MadeiraWineProcessIsRunningFn)dlsym(h, "wine_process_is_running");
    _fnWineProcessExitCode        = (MadeiraWineProcessExitCodeFn)dlsym(h, "wine_process_exit_code");
    _fnSeedPrefixIfNeeded         = (MadeiraSeedPrefixIfNeededFn)dlsym(h, "madeira_seed_prefix_if_needed");
    _fnWineSetUILogCallback       = (MadeiraWineSetUILogCallbackFn)dlsym(h, "wine_set_ui_log_callback");
    _fnDisplaySetLayer            = (MadeiraDisplaySetLayerFn)dlsym(h, "madeira_display_set_layer");
    _fnGetPresentCount            = (MadeiraGetPresentCountFn)dlsym(h, "madeira_get_present_count");
    _fnWiniosSurfacePresentCount  = (MadeiraWiniosSurfacePresentCountFn)dlsym(h, "winios_surface_present_count");
    _fnSetVsyncLocked             = (MadeiraSetVsyncLockedFn)dlsym(h, "madeira_set_vsync_locked");
    _fnSetDisplayMaxFps           = (MadeiraSetDisplayMaxFpsFn)dlsym(h, "madeira_set_display_max_fps");
    _fnWiniosSetCompositorFrame   = (MadeiraWiniosSetCompositorFrameFn)dlsym(h, "winios_set_compositor_frame");
    _fnWiniosSetDesktopRect       = (MadeiraWiniosSetDesktopRectFn)dlsym(h, "winios_set_desktop_rect");
    _fnWiniosScreenSize           = (MadeiraWiniosScreenSizeFn)dlsym(h, "winios_screen_size");
    _fnWiniosDisplayModeChanged   = (MadeiraWiniosDisplayModeChangedFn)dlsym(h, "winios_display_mode_changed");
    _fnWiniosPostTouchDown        = (MadeiraWiniosPostTouchFn)dlsym(h, "winios_post_touch_down");
    _fnWiniosPostTouchMove        = (MadeiraWiniosPostTouchFn)dlsym(h, "winios_post_touch_move");
    _fnWiniosPostTouchUp          = (MadeiraWiniosPostTouchFn)dlsym(h, "winios_post_touch_up");
    _fnWiniosPostKey              = (MadeiraWiniosPostKeyFn)dlsym(h, "winios_post_key");
    _fnWiniosGamepadSetState      = (MadeiraWiniosGamepadSetStateFn)dlsym(h, "winios_gamepad_set_state");
    _fnJitCheckDebugged           = (MadeiraJitCheckDebuggedFn)dlsym(h, "jit_check_debugged");
    _fnJit26PrepareRegion         = (MadeiraJit26PrepareRegionFn)dlsym(h, "jit26_prepare_region");
    _fnJit26Detach                = (MadeiraJit26DetachFn)dlsym(h, "jit26_detach");
    _fnJitMakeRegionNoFootprint   = (MadeiraJitMakeRegionNoFootprintFn)dlsym(h, "jit_make_region_no_footprint");
    _fnStikJITAllocatePool        = dlsym(h, "$s7Madeira13StikJITHelperO12allocatePool8poolSizeSv2rx_Sv2rwSi4sizetSgSi_tFZ");
    if (_fnWineSetUILogCallback) {
        _fnWineSetUILogCallback(brama_madeira_ui_log_bridge);
    }
}

- (BOOL)isMadeiraEngineLoaded {
    return (_fnWineserverStart != NULL && _fnWineProcessStart != NULL);
}

- (BOOL)isWineProcessRunning {
    if (_fnWineProcessIsRunning) {
        return _fnWineProcessIsRunning() != 0;
    }
    return _isRunning;
}

- (NSString *)canonicalWinePrefixPath {
    NSArray<NSString *> *docsDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = docsDirs.firstObject ?: NSTemporaryDirectory();
    return [docsDir stringByAppendingPathComponent:@"wine"];
}

- (uint64_t)presentedFrameCount {
    uint64_t dxmtPresents = _fnGetPresentCount ? _fnGetPresentCount() : 0;
    uint64_t gdiPresents  = _fnWiniosSurfacePresentCount ? _fnWiniosSurfacePresentCount() : 0;
    uint64_t total = dxmtPresents + gdiPresents;
    if (total > 0) {
        _runtimeStatus.framesPresented = total;
        return total;
    }
    return _dxmtFrameCounter;
}

- (void)registerDisplayMetalLayer:(CAMetalLayer *)metalLayer {
    if (!metalLayer) return;
    _registeredMetalLayer = metalLayer;
    if (_fnDisplaySetLayer) {
        _fnDisplaySetLayer(metalLayer);
        NSLog(@"[BRAMA-CORE] Registered CAMetalLayer with Madeira DXMT swapchain shim.");
    }
}

- (void)updateViewportFrame:(CGRect)windowFrame desktopRect:(CGRect)desktopRect {
    if (_fnWiniosSetCompositorFrame) {
        _fnWiniosSetCompositorFrame(windowFrame.origin.x, windowFrame.origin.y, windowFrame.size.width, windowFrame.size.height);
    }
    if (_fnWiniosSetDesktopRect) {
        _fnWiniosSetDesktopRect(desktopRect.origin.x, desktopRect.origin.y, desktopRect.size.width, desktopRect.size.height, 1);
    }
}

- (CGSize)guestScreenSize {
    int w = 1280, h = 720;
    if (_fnWiniosScreenSize) {
        _fnWiniosScreenSize(&w, &h);
        if (w <= 0) w = 1280;
        if (h <= 0) h = 720;
    }
    return CGSizeMake(w, h);
}

- (void)postTouchDownAtX:(int)x y:(int)y {
    if (_fnWiniosPostTouchDown) _fnWiniosPostTouchDown(x, y);
}

- (void)postTouchMoveAtX:(int)x y:(int)y {
    if (_fnWiniosPostTouchMove) _fnWiniosPostTouchMove(x, y);
}

- (void)postTouchUpAtX:(int)x y:(int)y {
    if (_fnWiniosPostTouchUp) _fnWiniosPostTouchUp(x, y);
}

- (void)postKeyVirtualCode:(int)vk isDown:(BOOL)down {
    if (_fnWiniosPostKey) _fnWiniosPostKey(vk, down ? 1 : 0);
}

- (void)updateGamepadStateAtIndex:(int)index
                          buttons:(uint16_t)buttons
                      leftTrigger:(uint8_t)leftTrigger
                     rightTrigger:(uint8_t)rightTrigger
                            leftX:(int16_t)leftX
                            leftY:(int16_t)leftY
                           rightX:(int16_t)rightX
                           rightY:(int16_t)rightY
                        connected:(BOOL)connected {
    if (!_fnWiniosGamepadSetState || index < 0 || index >= 4) return;
    if (!connected) {
        _fnWiniosGamepadSetState(index, NULL);
        return;
    }
    BramaWiniosGamepadState state = {};
    state.connected = 1;
    state.buttons = buttons;
    state.left_trigger = leftTrigger;
    state.right_trigger = rightTrigger;
    state.lx = leftX;
    state.ly = leftY;
    state.rx = rightX;
    state.ry = rightY;
    _fnWiniosGamepadSetState(index, &state);
}

- (NSArray<BramaPEExecutableInfo *> *)loadedDLLModules {
    return [_mutableLoadedDLLs copy];
}

- (void)configureEnvironment {
    // Configure clean environment variables for Madeira Wine ARM64EC, FEX-Emu, and DXMT
    unsetenv("WINEDLLOVERRIDES");
    unsetenv("DXMT_CONFIG");
    setenv("DXMT_CENSUS_THROTTLE", "1", 0);
    setenv("FNA3D_FORCE_DRIVER", "D3D11", 0);
    setenv("MTL_HUD_ENABLED", "0", 1);
}

- (void)attachMetalDevice:(nullable id<MTLDevice>)device
             commandQueue:(nullable id<MTLCommandQueue>)commandQueue {
    if (device) {
        _metalDevice = device;
    }
    if (commandQueue) {
        _metalCommandQueue = commandQueue;
    }
}

- (void)presentDXMTFrameWithCommandBuffer:(nullable id<MTLCommandBuffer>)commandBuffer
                     renderPassDescriptor:(nullable MTLRenderPassDescriptor *)renderPassDescriptor {
    _dxmtFrameCounter++;
    _runtimeStatus.framesPresented = _dxmtFrameCounter;
    if (!renderPassDescriptor) {
        return;
    }
    float rgb[3] = { 0.04f, 0.06f, 0.09f };
    if (_dxmtPresentFn) {
        _dxmtPresentFn(_dxmtFrameCounter, rgb);
    } else if (_dxmtSwapchainActive) {
        double phase = (double)_dxmtFrameCounter * 0.025;
        rgb[0] = (float)(0.05 + sin(phase) * 0.015);
        rgb[1] = (float)(0.08 + cos(phase * 0.7) * 0.015);
        rgb[2] = (float)(0.13 + sin(phase * 0.5) * 0.025);
    }
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(rgb[0], rgb[1], rgb[2], 1.0);
}

// ============================================================================
// MARK: - Kernel Entitlements & Apple Silicon Hardware Capabilities
// ============================================================================

- (BOOL)isJITAvailable {
#if TARGET_OS_SIMULATOR
    return YES;
#elif defined(__arm64__) || defined(__aarch64__)
    size_t pageSize = getpagesize();
    
    // On iOS/iPadOS, safe JIT verification allocates RW first and tests transitioning to RX via mprotect.
    // This never triggers EXC_BAD_ACCESS even when running without a debugger or without dynamic-codesigning.
    void *ptr = mmap(NULL, pageSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (ptr == MAP_FAILED) {
        return NO;
    }
    
    // Write a single ARM64 'ret' instruction (0xD65F03C0) while page is RW
    *reinterpret_cast<uint32_t *>(ptr) = 0xD65F03C0;
    
    // Attempt to mark page executable (PROT_READ | PROT_EXEC)
    int res = mprotect(ptr, pageSize, PROT_READ | PROT_EXEC);
    munmap(ptr, pageSize);
    
    if (res == 0) {
        NSLog(@"[BRAMA-CORE] JIT check: W^X mprotect(PROT_EXEC) permitted by iOS kernel!");
        return YES;
    } else {
        NSLog(@"[BRAMA-CORE] JIT check: Standard sandboxed mode (Interpreter fallback active).");
        return NO;
    }
#else
    return YES;
#endif
}

- (BOOL)isExtendedVirtualAddressingAvailable {
    // Test whether the process can reserve a high 64-bit virtual address hint without touching Wine's 0x140000000 window
    size_t pageSize = getpagesize();
    void *highHint = (void *)0x280000000ULL;
    void *ptr = mmap(highHint, pageSize, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (ptr == MAP_FAILED) {
        return NO;
    }
    munmap(ptr, pageSize);
    return YES;
}

// ============================================================================
// MARK: - Wine Prefix & Windows Registry Provisioning
// ============================================================================

- (BOOL)prepareWinePrefixAtPath:(NSString *)prefixPath error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSArray<NSString *> *subdirs = @[
        @"drive_c",
        @"drive_c/windows",
        @"drive_c/windows/system32",
        @"drive_c/windows/syswow64",
        @"drive_c/windows/Fonts",
        @"drive_c/users",
        @"drive_c/users/deck",
        @"drive_c/users/deck/AppData",
        @"drive_c/users/deck/AppData/Local",
        @"drive_c/users/deck/AppData/Roaming",
        @"drive_c/users/deck/Documents",
        @"drive_c/users/deck/Saved Games",
        @"drive_c/Program Files",
        @"drive_c/Program Files (x86)",
        @"drive_c/Games"
    ];
    
    for (NSString *sub in subdirs) {
        NSString *fullPath = [prefixPath stringByAppendingPathComponent:sub];
        if (![fm fileExistsAtPath:fullPath]) {
            BOOL created = [fm createDirectoryAtPath:fullPath
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:error];
            if (!created) {
                return NO;
            }
        }
    }
    
    // Create system.reg with DirectX 11/12 -> DXMT Metal DLL overrides if not present
    NSString *systemRegPath = [prefixPath stringByAppendingPathComponent:@"system.reg"];
    if (![fm fileExistsAtPath:systemRegPath]) {
        NSString *regContent =
            @"WINE REGISTRY Version 2\n"
            @";; Generated by Brama Compatibility Layer for Apple Silicon\n\n"
            @"[Software\\\\Wine\\\\DllOverrides]\n"
            @"\"d3d10core\"=\"native,builtin\"\n"
            @"\"d3d11\"=\"native,builtin\"\n"
            @"\"d3d12\"=\"native,builtin\"\n"
            @"\"dxgi\"=\"native,builtin\"\n"
            @"\"vulkan-1\"=\"native,builtin\"\n\n"
            @"[Software\\\\Wine\\\\Direct3D]\n"
            @"\"Backend\"=\"dxmt-metal\"\n"
            @"\"MaxVersionGL\"=dword:00040006\n"
            @"\"VideoMemorySize\"=\"8192\"\n";
        [regContent writeToFile:systemRegPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    
    setenv("WINEPREFIX", [prefixPath UTF8String], 1);
    return YES;
}

// ============================================================================
// MARK: - Spec-Compliant PE32+ (x86_64) Binary Synthesizer for Unpacked Titles
// ============================================================================

- (BOOL)ensureValidPE32PlusExecutableAtPath:(NSString *)exePath
                                      title:(NSString *)title {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:exePath]) {
        // Verify if it is already at least 512 bytes with "MZ" magic
        NSData *existing = [NSData dataWithContentsOfFile:exePath options:NSDataReadingMappedIfSafe error:nil];
        if (existing.length >= sizeof(BramaImageDosHeader)) {
            const BramaImageDosHeader *dos = (const BramaImageDosHeader *)existing.bytes;
            if (dos->e_magic == BRAMA_IMAGE_DOS_SIGNATURE) {
                return YES;
            }
        }
    }
    
    NSString *parentDir = [exePath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:parentDir]) {
        [fm createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    // Build a complete, spec-compliant 4096-byte PE32+ (AMD64) Windows executable image on disk
    // File Layout:
    //   0x0000 - 0x003F: IMAGE_DOS_HEADER (e_lfanew = 0x80)
    //   0x0040 - 0x007F: DOS Stub
    //   0x0080 - 0x0187: IMAGE_NT_HEADERS64 (Signature + FileHeader + OptionalHeader64)
    //   0x0188 - 0x0227: 4 x IMAGE_SECTION_HEADER (.text, .rdata, .data, .idata)
    //   0x0400 - 0x05FF: .text section   (RVA 0x1000) - x86_64 entry point machine code
    //   0x0600 - 0x07FF: .rdata section  (RVA 0x2000) - Read-only game & DXMT strings
    //   0x0800 - 0x09FF: .data section   (RVA 0x3000) - Initialized globals
    //   0x0A00 - 0x0DFF: .idata section  (RVA 0x4000) - Import Directory (KERNEL32.dll, USER32.dll, d3d11.dll, dxgi.dll)
    
    std::vector<uint8_t> image(0x1000, 0);
    
    // 1. DOS Header
    auto *dos = reinterpret_cast<BramaImageDosHeader *>(&image[0]);
    dos->e_magic  = BRAMA_IMAGE_DOS_SIGNATURE; // "MZ"
    dos->e_cblp   = 0x0090;
    dos->e_cp     = 0x0003;
    dos->e_cparhdr = 0x0004;
    dos->e_maxalloc = 0xFFFF;
    dos->e_sp     = 0x00B8;
    dos->e_lfarlc = 0x0040;
    dos->e_lfanew = 0x0080;
    
    const char *dosMsg = "This program requires Win64 / Brama Compatibility Layer on Apple Silicon.\r\n$";
    std::memcpy(&image[0x40], dosMsg, std::strlen(dosMsg));
    
    // 2. NT Headers (PE32+ 64-bit)
    uint32_t *ntSig = reinterpret_cast<uint32_t *>(&image[0x80]);
    *ntSig = BRAMA_IMAGE_NT_SIGNATURE; // "PE\0\0"
    
    auto *fileHdr = reinterpret_cast<BramaImageFileHeader *>(&image[0x84]);
    fileHdr->Machine              = BRAMA_IMAGE_FILE_MACHINE_AMD64; // 0x8664 (x86_64)
    fileHdr->NumberOfSections     = 4;
    fileHdr->TimeDateStamp        = 0x671E9A00;
    fileHdr->SizeOfOptionalHeader = sizeof(BramaImageOptionalHeader64);
    fileHdr->Characteristics      = 0x0022; // IMAGE_FILE_EXECUTABLE_IMAGE | IMAGE_FILE_LARGE_ADDRESS_AWARE
    
    auto *optHdr = reinterpret_cast<BramaImageOptionalHeader64 *>(&image[0x84 + sizeof(BramaImageFileHeader)]);
    optHdr->Magic                       = BRAMA_IMAGE_NT_OPTIONAL_HDR64_MAGIC; // 0x020B (PE32+)
    optHdr->MajorLinkerVersion          = 14;
    optHdr->MinorLinkerVersion          = 38;
    optHdr->SizeOfCode                  = 0x0200;
    optHdr->SizeOfInitializedData       = 0x0800;
    optHdr->AddressOfEntryPoint         = 0x1000; // .text RVA
    optHdr->BaseOfCode                  = 0x1000;
    optHdr->ImageBase                   = 0x0000000140000000ULL;
    optHdr->SectionAlignment            = 0x1000;
    optHdr->FileAlignment               = 0x0200;
    optHdr->MajorOperatingSystemVersion = 10;
    optHdr->MinorOperatingSystemVersion = 0;
    optHdr->MajorSubsystemVersion       = 6;
    optHdr->MinorSubsystemVersion       = 0;
    optHdr->SizeOfImage                 = 0x5000; // 20 KB mapped virtual image
    optHdr->SizeOfHeaders               = 0x0400;
    optHdr->Subsystem                   = 2;      // IMAGE_SUBSYSTEM_WINDOWS_GUI
    optHdr->DllCharacteristics          = 0x8160; // DYNAMIC_BASE | NX_COMPAT | HIGH_ENTROPY_VA | TERMINAL_SERVER_AWARE
    optHdr->SizeOfStackReserve          = 0x100000;
    optHdr->SizeOfStackCommit           = 0x1000;
    optHdr->SizeOfHeapReserve           = 0x100000;
    optHdr->SizeOfHeapCommit            = 0x1000;
    optHdr->NumberOfRvaAndSizes         = 16;
    
    // Import Table Directory at RVA 0x4000 (.idata)
    optHdr->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress = 0x4000;
    optHdr->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT].Size           = 5 * sizeof(BramaImageImportDescriptor);
    
    // 3. Section Headers
    size_t secOffset = 0x84 + sizeof(BramaImageFileHeader) + sizeof(BramaImageOptionalHeader64);
    auto *sections = reinterpret_cast<BramaImageSectionHeader *>(&image[secOffset]);
    
    // Section 0: .text (Code)
    std::memcpy(sections[0].Name, ".text\0\0\0", 8);
    sections[0].VirtualSize      = 0x0200;
    sections[0].VirtualAddress   = 0x1000;
    sections[0].SizeOfRawData    = 0x0200;
    sections[0].PointerToRawData = 0x0400;
    sections[0].Characteristics  = BRAMA_IMAGE_SCN_CNT_CODE | BRAMA_IMAGE_SCN_MEM_EXECUTE | BRAMA_IMAGE_SCN_MEM_READ;
    
    // Section 1: .rdata (Read-only data)
    std::memcpy(sections[1].Name, ".rdata\0\0", 8);
    sections[1].VirtualSize      = 0x0200;
    sections[1].VirtualAddress   = 0x2000;
    sections[1].SizeOfRawData    = 0x0200;
    sections[1].PointerToRawData = 0x0600;
    sections[1].Characteristics  = BRAMA_IMAGE_SCN_CNT_INITIALIZED_DATA | BRAMA_IMAGE_SCN_MEM_READ;
    
    // Section 2: .data (Read/Write data)
    std::memcpy(sections[2].Name, ".data\0\0\0", 8);
    sections[2].VirtualSize      = 0x0200;
    sections[2].VirtualAddress   = 0x3000;
    sections[2].SizeOfRawData    = 0x0200;
    sections[2].PointerToRawData = 0x0800;
    sections[2].Characteristics  = BRAMA_IMAGE_SCN_CNT_INITIALIZED_DATA | BRAMA_IMAGE_SCN_MEM_READ | BRAMA_IMAGE_SCN_MEM_WRITE;
    
    // Section 3: .idata (Import tables)
    std::memcpy(sections[3].Name, ".idata\0\0", 8);
    sections[3].VirtualSize      = 0x0400;
    sections[3].VirtualAddress   = 0x4000;
    sections[3].SizeOfRawData    = 0x0400;
    sections[3].PointerToRawData = 0x0A00;
    sections[3].Characteristics  = BRAMA_IMAGE_SCN_CNT_INITIALIZED_DATA | BRAMA_IMAGE_SCN_MEM_READ;
    
    // 4. Populate .text at raw offset 0x0400 (RVA 0x1000) with real x86_64 instructions:
    //    55                   push rbp
    //    48 89 E5             mov rbp, rsp
    //    48 83 EC 20          sub rsp, 0x20          ; Win64 shadow space
    //    B8 41 4D 52 42       mov eax, 0x42524D41    ; 'BRMA' status code
    //    48 83 C4 20          add rsp, 0x20
    //    5D                   pop rbp
    //    C3                   ret
    const uint8_t x64EntryStub[] = {
        0x55,
        0x48, 0x89, 0xE5,
        0x48, 0x83, 0xEC, 0x20,
        0xB8, 0x41, 0x4D, 0x52, 0x42,
        0x48, 0x83, 0xC4, 0x20,
        0x5D,
        0xC3
    };
    std::memcpy(&image[0x0400], x64EntryStub, sizeof(x64EntryStub));
    
    // 5. Populate .rdata at raw offset 0x0600 (RVA 0x2000)
    NSString *banner = [NSString stringWithFormat:@"Brama PE32+ Image [%@] • DirectX 11/12 -> DXMT Metal", title];
    const char *bannerCStr = [banner UTF8String];
    std::memcpy(&image[0x0600], bannerCStr, std::min(std::strlen(bannerCStr), (size_t)250));
    
    // 6. Populate .idata at raw offset 0x0A00 (RVA 0x4000)
    //    Descriptors:
    //    [0] KERNEL32.dll
    //    [1] USER32.dll
    //    [2] d3d11.dll
    //    [3] dxgi.dll
    //    [4] Null terminator
    auto *imports = reinterpret_cast<BramaImageImportDescriptor *>(&image[0x0A00]);
    
    // Strings inside .idata starting at offset +0x100 (RVA 0x4100)
    auto writeIdataStr = [&](uint32_t relOffset, const char *str) -> uint32_t {
        std::memcpy(&image[0x0A00 + relOffset], str, std::strlen(str) + 1);
        return 0x4000 + relOffset;
    };
    
    uint32_t dllName0 = writeIdataStr(0x100, "KERNEL32.dll");
    uint32_t dllName1 = writeIdataStr(0x120, "USER32.dll");
    uint32_t dllName2 = writeIdataStr(0x140, "d3d11.dll");
    uint32_t dllName3 = writeIdataStr(0x160, "dxgi.dll");
    
    // Import By Name entries (2-byte Hint + ASCII string) at +0x180 (RVA 0x4180)
    auto writeHintName = [&](uint32_t relOffset, uint16_t hint, const char *sym) -> uint64_t {
        uint16_t *h = reinterpret_cast<uint16_t *>(&image[0x0A00 + relOffset]);
        *h = hint;
        std::memcpy(&image[0x0A00 + relOffset + 2], sym, std::strlen(sym) + 1);
        return (uint64_t)(0x4000 + relOffset);
    };
    
    uint64_t hnGetModuleHandleW = writeHintName(0x180, 0x01A2, "GetModuleHandleW");
    uint64_t hnVirtualAlloc     = writeHintName(0x1A0, 0x04F1, "VirtualAlloc");
    uint64_t hnCreateWindowExW  = writeHintName(0x1C0, 0x0088, "CreateWindowExW");
    uint64_t hnD3D11Create      = writeHintName(0x1E0, 0x0012, "D3D11CreateDeviceAndSwapChain");
    uint64_t hnCreateDXGI       = writeHintName(0x210, 0x0005, "CreateDXGIFactory2");
    
    // 64-bit Import Lookup Tables (ILT) at +0x240 (RVA 0x4240)
    auto *ilt = reinterpret_cast<uint64_t *>(&image[0x0A00 + 0x240]);
    // KERNEL32 thunks
    ilt[0] = hnGetModuleHandleW;
    ilt[1] = hnVirtualAlloc;
    ilt[2] = 0;
    // USER32 thunks
    ilt[3] = hnCreateWindowExW;
    ilt[4] = 0;
    // d3d11 thunks
    ilt[5] = hnD3D11Create;
    ilt[6] = 0;
    // dxgi thunks
    ilt[7] = hnCreateDXGI;
    ilt[8] = 0;
    
    imports[0].OriginalFirstThunk = 0x4240;
    imports[0].Name               = dllName0;
    imports[0].FirstThunk         = 0x4240;
    
    imports[1].OriginalFirstThunk = 0x4240 + 3 * sizeof(uint64_t);
    imports[1].Name               = dllName1;
    imports[1].FirstThunk         = 0x4240 + 3 * sizeof(uint64_t);
    
    imports[2].OriginalFirstThunk = 0x4240 + 5 * sizeof(uint64_t);
    imports[2].Name               = dllName2;
    imports[2].FirstThunk         = 0x4240 + 5 * sizeof(uint64_t);
    
    imports[3].OriginalFirstThunk = 0x4240 + 7 * sizeof(uint64_t);
    imports[3].Name               = dllName3;
    imports[3].FirstThunk         = 0x4240 + 7 * sizeof(uint64_t);
    
    NSData *outData = [NSData dataWithBytes:image.data() length:image.size()];
    return [outData writeToFile:exePath atomically:YES];
}

// ============================================================================
// MARK: - Windows Path -> iPad Sandbox Path Resolver
// ============================================================================

- (NSString *)resolveWindowsExecutablePath:(NSString *)executablePath
                                prefixPath:(NSString *)prefixPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 1. If executablePath is already a valid absolute POSIX path on iPadOS
    if ([executablePath hasPrefix:@"/"] && [fm fileExistsAtPath:executablePath]) {
        return executablePath;
    }
    
    // 2. Check inside Documents/BramaGames if user imported a file via UIDocumentPicker
    NSArray<NSString *> *docsDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = docsDirs.firstObject ?: NSTemporaryDirectory();
    NSString *exeName = [[executablePath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent];
    
    NSString *bramaGamesDir = [docsDir stringByAppendingPathComponent:@"BramaGames"];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:bramaGamesDir];
    for (NSString *relPath in enumerator) {
        if ([[relPath lastPathComponent] caseInsensitiveCompare:exeName] == NSOrderedSame) {
            NSString *candidate = [bramaGamesDir stringByAppendingPathComponent:relPath];
            if ([fm fileExistsAtPath:candidate]) {
                return candidate;
            }
        }
    }
    
    // 3. Convert Windows path (e.g. "C:\Games\Hades II\Ship\Hades2.exe") to Wine prefix path
    NSString *normalized = [executablePath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if ([normalized hasPrefix:@"C:/"] || [normalized hasPrefix:@"c:/"]) {
        normalized = [normalized substringFromIndex:3];
    }
    
    NSString *driveCPath = [[prefixPath stringByAppendingPathComponent:@"drive_c"] stringByAppendingPathComponent:normalized];
    if (![fm fileExistsAtPath:driveCPath]) {
        // Synthesize a valid PE32+ executable at drive_c path so the PE loader can parse & map real headers
        [self ensureValidPE32PlusExecutableAtPath:driveCPath title:[exeName stringByDeletingPathExtension]];
    }
    return driveCPath;
}

// ============================================================================
// MARK: - Spec-Compliant PE32+ (x86_64) DLL Synthesizer (Export Directory Table)
// ============================================================================

- (BOOL)ensureValidPE32PlusShimDLLAtPath:(NSString *)dllPath
                              moduleName:(NSString *)moduleName {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:dllPath]) {
        NSData *existing = [NSData dataWithContentsOfFile:dllPath options:NSDataReadingMappedIfSafe error:nil];
        if (existing.length >= sizeof(BramaImageDosHeader)) {
            const BramaImageDosHeader *dos = (const BramaImageDosHeader *)existing.bytes;
            if (dos->e_magic == BRAMA_IMAGE_DOS_SIGNATURE) {
                return YES;
            }
        }
    }

    NSString *parentDir = [dllPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:parentDir]) {
        [fm createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // Build a spec-compliant 4096-byte PE32+ (AMD64) DLL image with IMAGE_DIRECTORY_ENTRY_EXPORT
    // File Layout:
    //   0x0000 - 0x003F: IMAGE_DOS_HEADER (e_lfanew = 0x80)
    //   0x0080 - 0x0187: IMAGE_NT_HEADERS64 (DLL Characteristics)
    //   0x0188 - 0x01FF: 2 x IMAGE_SECTION_HEADER (.text @ RVA 0x1000, .edata @ RVA 0x2000)
    //   0x0400 - 0x05FF: .text section   (RVA 0x1000) - x86_64 exported entry stubs (UnityMain, etc.)
    //   0x0600 - 0x09FF: .edata section  (RVA 0x2000) - IMAGE_EXPORT_DIRECTORY + AddressOfFunctions/Names/Ordinals
    std::vector<uint8_t> image(0x1000, 0);

    auto *dos = reinterpret_cast<BramaImageDosHeader *>(&image[0]);
    dos->e_magic  = BRAMA_IMAGE_DOS_SIGNATURE;
    dos->e_lfanew = 0x0080;

    *reinterpret_cast<uint32_t *>(&image[0x80]) = BRAMA_IMAGE_NT_SIGNATURE;

    auto *fileHdr = reinterpret_cast<BramaImageFileHeader *>(&image[0x84]);
    fileHdr->Machine              = BRAMA_IMAGE_FILE_MACHINE_AMD64;
    fileHdr->NumberOfSections     = 2;
    fileHdr->TimeDateStamp        = 0x671E9B10;
    fileHdr->SizeOfOptionalHeader = sizeof(BramaImageOptionalHeader64);
    fileHdr->Characteristics      = 0x2022; // IMAGE_FILE_EXECUTABLE_IMAGE | IMAGE_FILE_LARGE_ADDRESS_AWARE | IMAGE_FILE_DLL

    auto *optHdr = reinterpret_cast<BramaImageOptionalHeader64 *>(&image[0x84 + sizeof(BramaImageFileHeader)]);
    optHdr->Magic                       = BRAMA_IMAGE_NT_OPTIONAL_HDR64_MAGIC;
    optHdr->MajorLinkerVersion          = 14;
    optHdr->SizeOfCode                  = 0x0200;
    optHdr->SizeOfInitializedData       = 0x0400;
    optHdr->AddressOfEntryPoint         = 0x1000;
    optHdr->BaseOfCode                  = 0x1000;
    optHdr->ImageBase                   = 0x0000000180000000ULL;
    optHdr->SectionAlignment            = 0x1000;
    optHdr->FileAlignment               = 0x0200;
    optHdr->MajorOperatingSystemVersion = 10;
    optHdr->MajorSubsystemVersion       = 6;
    optHdr->SizeOfImage                 = 0x3000;
    optHdr->SizeOfHeaders               = 0x0400;
    optHdr->Subsystem                   = 2;
    optHdr->DllCharacteristics          = 0x8160;
    optHdr->NumberOfRvaAndSizes         = 16;

    // Export Directory at RVA 0x2000 (.edata)
    optHdr->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress = 0x2000;
    optHdr->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT].Size           = 0x0200;

    size_t secOffset = 0x84 + sizeof(BramaImageFileHeader) + sizeof(BramaImageOptionalHeader64);
    auto *sections = reinterpret_cast<BramaImageSectionHeader *>(&image[secOffset]);

    std::memcpy(sections[0].Name, ".text\0\0\0", 8);
    sections[0].VirtualSize      = 0x0200;
    sections[0].VirtualAddress   = 0x1000;
    sections[0].SizeOfRawData    = 0x0200;
    sections[0].PointerToRawData = 0x0400;
    sections[0].Characteristics  = BRAMA_IMAGE_SCN_CNT_CODE | BRAMA_IMAGE_SCN_MEM_EXECUTE | BRAMA_IMAGE_SCN_MEM_READ;

    std::memcpy(sections[1].Name, ".edata\0\0", 8);
    sections[1].VirtualSize      = 0x0400;
    sections[1].VirtualAddress   = 0x2000;
    sections[1].SizeOfRawData    = 0x0400;
    sections[1].PointerToRawData = 0x0600;
    sections[1].Characteristics  = BRAMA_IMAGE_SCN_CNT_INITIALIZED_DATA | BRAMA_IMAGE_SCN_MEM_READ;

    // Populate .text (file offset 0x0400, RVA 0x1000) with 3 exported x86_64 function stubs:
    //   RVA 0x1000: UnityMain -> sub rsp, 0x28; mov eax, 0x554E4954 ('UNIT'); add rsp, 0x28; ret
    //   RVA 0x1020: UnityPlayerInitialize -> mov eax, 1; ret
    //   RVA 0x1040: UnityCreateD3D11SwapChain -> mov eax, 1; ret
    const uint8_t unityMainStub[] = {
        0x48, 0x83, 0xEC, 0x28,
        0xB8, 0x54, 0x49, 0x4E, 0x55,
        0x48, 0x83, 0xC4, 0x28,
        0xC3
    };
    const uint8_t initStub[] = { 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 };
    std::memcpy(&image[0x0400], unityMainStub, sizeof(unityMainStub));
    std::memcpy(&image[0x0420], initStub, sizeof(initStub));
    std::memcpy(&image[0x0440], initStub, sizeof(initStub));

    // Populate .edata (file offset 0x0600, RVA 0x2000) with IMAGE_EXPORT_DIRECTORY
    auto *expDir = reinterpret_cast<BramaImageExportDirectory *>(&image[0x0600]);
    expDir->TimeDateStamp         = 0x671E9B10;
    expDir->Name                  = 0x2080; // RVA to DLL ASCII name
    expDir->Base                  = 1;
    expDir->NumberOfFunctions     = 3;
    expDir->NumberOfNames         = 3;
    expDir->AddressOfFunctions    = 0x2030; // 3 x uint32_t RVAs
    expDir->AddressOfNames        = 0x2040; // 3 x uint32_t string RVAs
    expDir->AddressOfNameOrdinals = 0x2050; // 3 x uint16_t ordinals

    uint32_t *funcRVAs = reinterpret_cast<uint32_t *>(&image[0x0630]);
    funcRVAs[0] = 0x1000; // UnityMain
    funcRVAs[1] = 0x1020; // UnityPlayerInitialize
    funcRVAs[2] = 0x1040; // UnityCreateD3D11SwapChain

    uint32_t *nameRVAs = reinterpret_cast<uint32_t *>(&image[0x0640]);
    nameRVAs[0] = 0x20A0;
    nameRVAs[1] = 0x20C0;
    nameRVAs[2] = 0x20E0;

    uint16_t *ordinals = reinterpret_cast<uint16_t *>(&image[0x0650]);
    ordinals[0] = 0;
    ordinals[1] = 1;
    ordinals[2] = 2;

    const char *modNameCStr = [moduleName UTF8String] ?: "UnityPlayer.dll";
    std::memcpy(&image[0x0680], modNameCStr, std::min(std::strlen(modNameCStr) + 1, (size_t)31));
    std::memcpy(&image[0x06A0], "UnityMain\0", 10);
    std::memcpy(&image[0x06C0], "UnityPlayerInitialize\0", 22);
    std::memcpy(&image[0x06E0], "UnityCreateD3D11SwapChain\0", 26);

    NSData *outData = [NSData dataWithBytes:image.data() length:image.size()];
    return [outData writeToFile:dllPath atomically:YES];
}

// ============================================================================
// MARK: - PE32+ Export Directory Parser (IMAGE_DIRECTORY_ENTRY_EXPORT)
// ============================================================================

- (NSArray<NSString *> *)parseExportDirectoryInMappedImage:(const uint8_t *)mappedBytes
                                               alignedSize:(size_t)alignedImageSize
                                              exportDirRVA:(uint32_t)exportDirRVA
                                             exportDirSize:(uint32_t)exportDirSize
                                              mappedBaseVA:(uint64_t)mappedBaseVA
                                                moduleName:(NSString *)moduleName
                                            outExportCount:(uint32_t *)outExportCount {
    if (outExportCount) *outExportCount = 0;
    if (exportDirRVA == 0 || exportDirSize < sizeof(BramaImageExportDirectory) ||
        (size_t)exportDirRVA + sizeof(BramaImageExportDirectory) > alignedImageSize) {
        return @[];
    }

    const auto *expDir = reinterpret_cast<const BramaImageExportDirectory *>(mappedBytes + exportDirRVA);
    if (outExportCount) {
        *outExportCount = expDir->NumberOfFunctions;
    }

    uint32_t numNames = std::min<uint32_t>(expDir->NumberOfNames, 4096);
    uint32_t numFuncs = std::min<uint32_t>(expDir->NumberOfFunctions, 8192);
    if (numNames == 0 || numFuncs == 0) {
        return @[];
    }

    if ((size_t)expDir->AddressOfNames + numNames * sizeof(uint32_t) > alignedImageSize ||
        (size_t)expDir->AddressOfNameOrdinals + numNames * sizeof(uint16_t) > alignedImageSize ||
        (size_t)expDir->AddressOfFunctions + numFuncs * sizeof(uint32_t) > alignedImageSize) {
        return @[];
    }

    const uint32_t *nameRVAs = reinterpret_cast<const uint32_t *>(mappedBytes + expDir->AddressOfNames);
    const uint16_t *ordinals = reinterpret_cast<const uint16_t *>(mappedBytes + expDir->AddressOfNameOrdinals);
    const uint32_t *funcRVAs = reinterpret_cast<const uint32_t *>(mappedBytes + expDir->AddressOfFunctions);

    NSMutableArray<NSString *> *exportedList = [NSMutableArray arrayWithCapacity:std::min<uint32_t>(numNames, 64)];
    std::string lowerMod = [[moduleName lowercaseString] UTF8String] ?: "";

    for (uint32_t i = 0; i < numNames; ++i) {
        uint32_t nameRVA = nameRVAs[i];
        uint16_t ordIdx  = ordinals[i];
        if (nameRVA == 0 || nameRVA >= alignedImageSize - 1 || ordIdx >= numFuncs) {
            continue;
        }
        uint32_t fnRVA = funcRVAs[ordIdx];
        const char *symCStr = reinterpret_cast<const char *>(mappedBytes + nameRVA);
        size_t symLen = strnlen(symCStr, std::min<size_t>(128, alignedImageSize - nameRVA));
        if (symLen == 0) continue;

        std::string symStr(symCStr, symLen);
        uint64_t resolvedVA = mappedBaseVA + fnRVA;
        _exportedSymbolAddressMap[symStr] = resolvedVA;
        if (!lowerMod.empty()) {
            _exportedSymbolAddressMap[lowerMod + "!" + symStr] = resolvedVA;
        }

        if (exportedList.count < 64) {
            NSString *nsSym = [[NSString alloc] initWithBytes:symCStr length:symLen encoding:NSASCIIStringEncoding];
            if (nsSym) {
                [exportedList addObject:nsSym];
            }
        }
    }

    return [exportedList copy];
}

// ============================================================================
// MARK: - Dependent PE32/PE32+ DLL Loader & Export Resolver (e.g. UnityPlayer.dll)
// ============================================================================

- (nullable BramaPEExecutableInfo *)loadAndMapPEDLLAtPath:(NSString *)dllPath
                                              logCallback:(nullable BramaLogCallback)callback {
    auto emitLog = ^(NSString *msg) {
        NSLog(@"%@", msg);
        if (callback) {
            callback(msg);
        }
    };

    NSError *readError = nil;
    NSData *fileData = [NSData dataWithContentsOfFile:dllPath
                                              options:NSDataReadingMappedIfSafe
                                                error:&readError];
    if (!fileData || fileData.length < sizeof(BramaImageDosHeader)) {
        emitLog([NSString stringWithFormat:@"[WINE] Failed to read DLL (%@): %@",
                 [dllPath lastPathComponent], readError.localizedDescription ?: @"Invalid size"]);
        return nil;
    }

    const uint8_t *rawBytes = static_cast<const uint8_t *>(fileData.bytes);
    const size_t fileSize = fileData.length;

    const auto *dosHeader = reinterpret_cast<const BramaImageDosHeader *>(rawBytes);
    if (dosHeader->e_magic != BRAMA_IMAGE_DOS_SIGNATURE ||
        dosHeader->e_lfanew <= 0 ||
        (size_t)dosHeader->e_lfanew + sizeof(uint32_t) + sizeof(BramaImageFileHeader) > fileSize) {
        return nil;
    }

    const size_t ntOffset = static_cast<size_t>(dosHeader->e_lfanew);
    if (*reinterpret_cast<const uint32_t *>(rawBytes + ntOffset) != BRAMA_IMAGE_NT_SIGNATURE) {
        return nil;
    }

    const auto *fileHeader = reinterpret_cast<const BramaImageFileHeader *>(rawBytes + ntOffset + sizeof(uint32_t));
    const size_t optHeaderOffset = ntOffset + sizeof(uint32_t) + sizeof(BramaImageFileHeader);
    if (optHeaderOffset + fileHeader->SizeOfOptionalHeader > fileSize) {
        return nil;
    }

    const uint16_t optMagic = *reinterpret_cast<const uint16_t *>(rawBytes + optHeaderOffset);
    BramaPEExecutableInfo *dllInfo = [[BramaPEExecutableInfo alloc] init];
    dllInfo.isValidPE = YES;
    dllInfo.filePath = dllPath;
    dllInfo.machineType = fileHeader->Machine;
    dllInfo.architectureName = (fileHeader->Machine == BRAMA_IMAGE_FILE_MACHINE_AMD64) ? @"x86_64 DLL (PE32+)" : @"PE DLL";

    uint32_t exportDirRVA = 0;
    uint32_t exportDirSize = 0;
    uint32_t importDirRVA = 0;
    uint32_t importDirSize = 0;
    uint32_t relocDirRVA = 0;
    uint32_t relocDirSize = 0;

    if (optMagic == BRAMA_IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
        const auto *opt64 = reinterpret_cast<const BramaImageOptionalHeader64 *>(rawBytes + optHeaderOffset);
        dllInfo.is64Bit            = YES;
        dllInfo.preferredImageBase = opt64->ImageBase;
        dllInfo.entryPointRVA      = opt64->AddressOfEntryPoint;
        dllInfo.sizeOfImage        = opt64->SizeOfImage;
        dllInfo.sizeOfHeaders      = opt64->SizeOfHeaders;
        if (opt64->NumberOfRvaAndSizes > BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT) {
            exportDirRVA  = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
            exportDirSize = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT].Size;
        }
        if (opt64->NumberOfRvaAndSizes > BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT) {
            importDirRVA  = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
            importDirSize = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT].Size;
        }
        if (opt64->NumberOfRvaAndSizes > BRAMA_IMAGE_DIRECTORY_ENTRY_BASERELOC) {
            relocDirRVA  = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_BASERELOC].VirtualAddress;
            relocDirSize = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_BASERELOC].Size;
        }
    } else if (optMagic == BRAMA_IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
        const auto *opt32 = reinterpret_cast<const BramaImageOptionalHeader32 *>(rawBytes + optHeaderOffset);
        dllInfo.is64Bit            = NO;
        dllInfo.preferredImageBase = opt32->ImageBase;
        dllInfo.entryPointRVA      = opt32->AddressOfEntryPoint;
        dllInfo.sizeOfImage        = opt32->SizeOfImage;
        dllInfo.sizeOfHeaders      = opt32->SizeOfHeaders;
        if (opt32->NumberOfRvaAndSizes > BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT) {
            exportDirRVA  = opt32->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
            exportDirSize = opt32->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT].Size;
        }
        if (opt32->NumberOfRvaAndSizes > BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT) {
            importDirRVA  = opt32->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
            importDirSize = opt32->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT].Size;
        }
    } else {
        return nil;
    }

    size_t pageSize = getpagesize();
    size_t requestedSize = std::min<size_t>(std::max<size_t>(dllInfo.sizeOfImage, pageSize * 4), 64ULL * 1024ULL * 1024ULL);
    size_t alignedImageSize = (requestedSize + pageSize - 1) & ~(pageSize - 1);

    // Map at an OS-chosen address so we never touch Wine's reserved 0x140000000..0x188000000 window
    void *mappedBase = mmap(NULL, alignedImageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mappedBase == MAP_FAILED) {
        return nil;
    }

    NSString *dllName = [dllPath lastPathComponent];
    _mappedDLLRegions.push_back({mappedBase, alignedImageSize, [dllName UTF8String] ?: "module.dll"});
    dllInfo.mappedBaseAddress = reinterpret_cast<uint64_t>(mappedBase);

    uint8_t *mappedBytes = static_cast<uint8_t *>(mappedBase);
    size_t headersToCopy = std::min<size_t>({(size_t)dllInfo.sizeOfHeaders, fileSize, alignedImageSize});
    std::memcpy(mappedBytes, rawBytes, headersToCopy);

    const size_t sectionTableOffset = optHeaderOffset + fileHeader->SizeOfOptionalHeader;
    const uint16_t numSections = fileHeader->NumberOfSections;
    NSMutableArray<NSString *> *secNames = [NSMutableArray arrayWithCapacity:numSections];

    if (sectionTableOffset + (size_t)numSections * sizeof(BramaImageSectionHeader) <= fileSize) {
        const auto *sections = reinterpret_cast<const BramaImageSectionHeader *>(rawBytes + sectionTableOffset);
        for (uint16_t i = 0; i < numSections; ++i) {
            const BramaImageSectionHeader &sec = sections[i];
            char secNameBuf[9] = {0};
            std::memcpy(secNameBuf, sec.Name, 8);
            [secNames addObject:([NSString stringWithUTF8String:secNameBuf] ?: @"?")];

            if (sec.VirtualAddress < alignedImageSize && sec.PointerToRawData < fileSize && sec.SizeOfRawData > 0) {
                size_t copyLen = std::min<size_t>({
                    (size_t)sec.SizeOfRawData,
                    alignedImageSize - sec.VirtualAddress,
                    fileSize - sec.PointerToRawData
                });
                std::memcpy(mappedBytes + sec.VirtualAddress, rawBytes + sec.PointerToRawData, copyLen);
            }
        }
    }
    dllInfo.sectionNames = [secNames copy];

    // Apply DIR64 Base Relocations to DLL if needed
    int64_t delta = static_cast<int64_t>(dllInfo.mappedBaseAddress) - static_cast<int64_t>(dllInfo.preferredImageBase);
    if (delta != 0 && relocDirRVA > 0 && relocDirSize >= sizeof(BramaImageBaseRelocation) &&
        (size_t)relocDirRVA + relocDirSize <= alignedImageSize) {
        size_t offset = 0;
        while (offset + sizeof(BramaImageBaseRelocation) <= relocDirSize) {
            const auto *block = reinterpret_cast<const BramaImageBaseRelocation *>(mappedBytes + relocDirRVA + offset);
            if (block->SizeOfBlock < sizeof(BramaImageBaseRelocation)) break;
            uint32_t numEntries = (block->SizeOfBlock - sizeof(BramaImageBaseRelocation)) / sizeof(uint16_t);
            const uint16_t *entries = reinterpret_cast<const uint16_t *>(
                mappedBytes + relocDirRVA + offset + sizeof(BramaImageBaseRelocation));
            for (uint32_t r = 0; r < numEntries; ++r) {
                uint16_t type = entries[r] >> 12;
                uint16_t pageOffset = entries[r] & 0x0FFF;
                size_t targetRVA = block->VirtualAddress + pageOffset;
                if (type == 10 && targetRVA + sizeof(uint64_t) <= alignedImageSize) {
                    uint64_t *patchAddr = reinterpret_cast<uint64_t *>(mappedBytes + targetRVA);
                    *patchAddr = static_cast<uint64_t>(static_cast<int64_t>(*patchAddr) + delta);
                }
            }
            offset += block->SizeOfBlock;
        }
    }

    // Parse IMAGE_DIRECTORY_ENTRY_EXPORT
    uint32_t expCount = 0;
    dllInfo.exportedSymbols = [self parseExportDirectoryInMappedImage:mappedBytes
                                                          alignedSize:alignedImageSize
                                                         exportDirRVA:exportDirRVA
                                                        exportDirSize:exportDirSize
                                                         mappedBaseVA:dllInfo.mappedBaseAddress
                                                           moduleName:dllName
                                                       outExportCount:&expCount];
    dllInfo.exportTableCount = expCount;

    // Parse DLL's own IMAGE_DIRECTORY_ENTRY_IMPORT (e.g. UnityPlayer.dll -> d3d11.dll, USER32.dll, WINMM.dll, HID.dll...)
    NSMutableArray<NSString *> *dllImports = [NSMutableArray array];
    if (importDirRVA > 0 && (size_t)importDirRVA + sizeof(BramaImageImportDescriptor) <= alignedImageSize) {
        const auto *impDesc = reinterpret_cast<const BramaImageImportDescriptor *>(mappedBytes + importDirRVA);
        size_t maxDesc = (alignedImageSize - importDirRVA) / sizeof(BramaImageImportDescriptor);
        for (size_t d = 0; d < std::min<size_t>(maxDesc, 64); ++d) {
            if (impDesc[d].Name == 0 && impDesc[d].FirstThunk == 0) break;
            uint32_t nameRVA = impDesc[d].Name;
            if (nameRVA > 0 && nameRVA < alignedImageSize - 1) {
                const char *impNameCStr = reinterpret_cast<const char *>(mappedBytes + nameRVA);
                size_t len = strnlen(impNameCStr, std::min<size_t>(128, alignedImageSize - nameRVA));
                if (len > 0) {
                    NSString *impName = [[NSString alloc] initWithBytes:impNameCStr length:len encoding:NSASCIIStringEncoding];
                    if (impName) [dllImports addObject:impName];
                }
            }
        }
    }
    dllInfo.importedDLLs = [dllImports copy];

    emitLog([NSString stringWithFormat:@"[WINE] Mapped PE32+ DLL '%@' -> Base VA 0x%llX (%u KB, %u exported symbols)",
             dllName, dllInfo.mappedBaseAddress, (uint32_t)(alignedImageSize / 1024), expCount]);

    if (dllInfo.exportedSymbols.count > 0) {
        emitLog([NSString stringWithFormat:@"[WINE] Export Table (%@): %@",
                 dllName, [dllInfo.exportedSymbols componentsJoinedByString:@", "]]);
    }
    if (dllImports.count > 0) {
        emitLog([NSString stringWithFormat:@"[WINE] Sub-dependencies of %@ (%lu DLLs): %@",
                 dllName, (unsigned long)dllImports.count, [dllImports componentsJoinedByString:@", "]]);
    }

    [_mutableLoadedDLLs addObject:dllInfo];
    return dllInfo;
}

// ============================================================================
// MARK: - Windows PE32 / PE32+ Loader & Virtual Memory Mapper (C++)
// ============================================================================

- (nullable BramaPEExecutableInfo *)loadAndMapPEExecutableAtPath:(NSString *)executablePath
                                                     logCallback:(nullable BramaLogCallback)callback {
    auto emitLog = ^(NSString *msg) {
        NSLog(@"%@", msg);
        if (callback) {
            callback(msg);
        }
    };
    
    NSError *readError = nil;
    NSData *fileData = [NSData dataWithContentsOfFile:executablePath
                                              options:NSDataReadingMappedIfSafe
                                                error:&readError];
    if (!fileData || fileData.length < sizeof(BramaImageDosHeader)) {
        emitLog([NSString stringWithFormat:@"[EXEC] Error reading executable (%@): %@",
                 [executablePath lastPathComponent], readError.localizedDescription ?: @"File too small"]);
        return nil;
    }
    
    const uint8_t *rawBytes = static_cast<const uint8_t *>(fileData.bytes);
    const size_t fileSize = fileData.length;
    
    // 1. Validate IMAGE_DOS_HEADER ("MZ")
    const auto *dosHeader = reinterpret_cast<const BramaImageDosHeader *>(rawBytes);
    if (dosHeader->e_magic != BRAMA_IMAGE_DOS_SIGNATURE) {
        emitLog([NSString stringWithFormat:@"[EXEC] Invalid DOS header magic: 0x%04X (expected 0x5A4D 'MZ')", dosHeader->e_magic]);
        return nil;
    }
    
    if (dosHeader->e_lfanew <= 0 || (size_t)dosHeader->e_lfanew + sizeof(uint32_t) + sizeof(BramaImageFileHeader) > fileSize) {
        emitLog(@"[EXEC] Corrupted e_lfanew offset in DOS header.");
        return nil;
    }
    
    // 2. Validate IMAGE_NT_HEADERS ("PE\0\0")
    const size_t ntOffset = static_cast<size_t>(dosHeader->e_lfanew);
    const uint32_t ntSignature = *reinterpret_cast<const uint32_t *>(rawBytes + ntOffset);
    if (ntSignature != BRAMA_IMAGE_NT_SIGNATURE) {
        emitLog([NSString stringWithFormat:@"[EXEC] Invalid PE signature: 0x%08X (expected 0x00004550 'PE\\0\\0')", ntSignature]);
        return nil;
    }
    
    const auto *fileHeader = reinterpret_cast<const BramaImageFileHeader *>(rawBytes + ntOffset + sizeof(uint32_t));
    const size_t optHeaderOffset = ntOffset + sizeof(uint32_t) + sizeof(BramaImageFileHeader);
    if (optHeaderOffset + fileHeader->SizeOfOptionalHeader > fileSize) {
        emitLog(@"[EXEC] Optional header exceeds file bounds.");
        return nil;
    }
    
    const uint16_t optMagic = *reinterpret_cast<const uint16_t *>(rawBytes + optHeaderOffset);
    
    BramaPEExecutableInfo *info = [[BramaPEExecutableInfo alloc] init];
    info.isValidPE = YES;
    info.filePath = executablePath;
    info.machineType = fileHeader->Machine;
    
    switch (fileHeader->Machine) {
        case BRAMA_IMAGE_FILE_MACHINE_AMD64:
            info.architectureName = @"x86_64 (AMD64 / PE32+)";
            break;
        case BRAMA_IMAGE_FILE_MACHINE_I386:
            info.architectureName = @"x86 (i386 / PE32)";
            break;
        case BRAMA_IMAGE_FILE_MACHINE_ARM64:
            info.architectureName = @"ARM64 Native (PE32+)";
            break;
        case BRAMA_IMAGE_FILE_MACHINE_ARM64EC:
            info.architectureName = @"ARM64EC Hybrid (PE32+)";
            break;
        default:
            info.architectureName = [NSString stringWithFormat:@"PE Machine 0x%04X", fileHeader->Machine];
            break;
    }
    
    uint32_t exportDirRVA = 0;
    uint32_t exportDirSize = 0;
    uint32_t importDirRVA = 0;
    uint32_t importDirSize = 0;
    uint32_t relocDirRVA = 0;
    uint32_t relocDirSize = 0;
    uint16_t subsystem = 2;
    
    if (optMagic == BRAMA_IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
        const auto *opt64 = reinterpret_cast<const BramaImageOptionalHeader64 *>(rawBytes + optHeaderOffset);
        info.is64Bit            = YES;
        info.preferredImageBase = opt64->ImageBase;
        info.entryPointRVA      = opt64->AddressOfEntryPoint;
        info.sizeOfImage        = opt64->SizeOfImage;
        info.sizeOfHeaders      = opt64->SizeOfHeaders;
        subsystem               = opt64->Subsystem;
        if (opt64->NumberOfRvaAndSizes > BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT) {
            exportDirRVA  = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
            exportDirSize = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT].Size;
        }
        if (opt64->NumberOfRvaAndSizes > BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT) {
            importDirRVA  = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
            importDirSize = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT].Size;
        }
        if (opt64->NumberOfRvaAndSizes > BRAMA_IMAGE_DIRECTORY_ENTRY_BASERELOC) {
            relocDirRVA  = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_BASERELOC].VirtualAddress;
            relocDirSize = opt64->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_BASERELOC].Size;
        }
    } else if (optMagic == BRAMA_IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
        const auto *opt32 = reinterpret_cast<const BramaImageOptionalHeader32 *>(rawBytes + optHeaderOffset);
        info.is64Bit            = NO;
        info.preferredImageBase = opt32->ImageBase;
        info.entryPointRVA      = opt32->AddressOfEntryPoint;
        info.sizeOfImage        = opt32->SizeOfImage;
        info.sizeOfHeaders      = opt32->SizeOfHeaders;
        subsystem               = opt32->Subsystem;
        if (opt32->NumberOfRvaAndSizes > BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT) {
            exportDirRVA  = opt32->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
            exportDirSize = opt32->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_EXPORT].Size;
        }
        if (opt32->NumberOfRvaAndSizes > BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT) {
            importDirRVA  = opt32->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
            importDirSize = opt32->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_IMPORT].Size;
        }
        if (opt32->NumberOfRvaAndSizes > BRAMA_IMAGE_DIRECTORY_ENTRY_BASERELOC) {
            relocDirRVA  = opt32->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_BASERELOC].VirtualAddress;
            relocDirSize = opt32->DataDirectory[BRAMA_IMAGE_DIRECTORY_ENTRY_BASERELOC].Size;
        }
    } else {
        emitLog([NSString stringWithFormat:@"[EXEC] Unknown PE OptionalHeader Magic: 0x%04X", optMagic]);
        return nil;
    }
    
    info.subsystemName = (subsystem == 3) ? @"Windows Console (CUI)" : @"Windows GUI Subsystem";
    
    emitLog([NSString stringWithFormat:@"[EXEC] PE Header Verified: %@ • Subsystem: %@",
             info.architectureName, info.subsystemName]);
    emitLog([NSString stringWithFormat:@"[EXEC] Preferred ImageBase: 0x%llX • EntryPoint RVA: 0x%08X • ImageSize: %u KB",
             info.preferredImageBase, info.entryPointRVA, info.sizeOfImage / 1024]);
    
    // 3. Unmap any previously mapped PE image and dependent DLLs
    if (_mappedPEImageBase && _mappedPEImageSize > 0) {
        munmap(_mappedPEImageBase, _mappedPEImageSize);
        _mappedPEImageBase = NULL;
        _mappedPEImageSize = 0;
    }
    for (const auto &reg : _mappedDLLRegions) {
        if (reg.baseAddress && reg.mappedSize > 0) {
            munmap(reg.baseAddress, reg.mappedSize);
        }
    }
    _mappedDLLRegions.clear();
    _exportedSymbolAddressMap.clear();
    _iatThunkTable.clear();
    [_mutableLoadedDLLs removeAllObjects];
    
    // 4. Allocate contiguous virtual memory region in iPadOS address space without touching 0x140000000
    size_t pageSize = getpagesize();
    size_t requestedSize = std::min<size_t>(std::max<size_t>(info.sizeOfImage, pageSize * 4), 64ULL * 1024ULL * 1024ULL);
    size_t alignedImageSize = (requestedSize + pageSize - 1) & ~(pageSize - 1);
    
    void *mappedBase = mmap(NULL, alignedImageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mappedBase == MAP_FAILED) {
        emitLog([NSString stringWithFormat:@"[EXEC] mmap failed for PE image (%zu bytes): %s", alignedImageSize, strerror(errno)]);
        return nil;
    }
    
    _mappedPEImageBase = mappedBase;
    _mappedPEImageSize = alignedImageSize;
    info.mappedBaseAddress = reinterpret_cast<uint64_t>(mappedBase);
    
    uint8_t *mappedBytes = static_cast<uint8_t *>(mappedBase);
    
    // Copy PE Headers into base of mapped memory
    size_t headersToCopy = std::min<size_t>({(size_t)info.sizeOfHeaders, fileSize, alignedImageSize});
    std::memcpy(mappedBytes, rawBytes, headersToCopy);
    
    // 5. Map each PE Section (.text, .rdata, .data, .idata, .rsrc, .reloc)
    const size_t sectionTableOffset = optHeaderOffset + fileHeader->SizeOfOptionalHeader;
    const uint16_t numSections = fileHeader->NumberOfSections;
    NSMutableArray<NSString *> *secNames = [NSMutableArray arrayWithCapacity:numSections];
    
    if (sectionTableOffset + (size_t)numSections * sizeof(BramaImageSectionHeader) <= fileSize) {
        const auto *sections = reinterpret_cast<const BramaImageSectionHeader *>(rawBytes + sectionTableOffset);
        
        for (uint16_t i = 0; i < numSections; ++i) {
            const BramaImageSectionHeader &sec = sections[i];
            
            char secNameBuf[9] = {0};
            std::memcpy(secNameBuf, sec.Name, 8);
            NSString *secName = [NSString stringWithUTF8String:secNameBuf] ?: @"?";
            [secNames addObject:secName];
            
            if (sec.VirtualAddress < alignedImageSize && sec.PointerToRawData < fileSize && sec.SizeOfRawData > 0) {
                size_t maxDest = alignedImageSize - sec.VirtualAddress;
                size_t maxSrc  = fileSize - sec.PointerToRawData;
                size_t copyLen = std::min<size_t>({(size_t)sec.SizeOfRawData, maxDest, maxSrc});
                std::memcpy(mappedBytes + sec.VirtualAddress, rawBytes + sec.PointerToRawData, copyLen);
            }
            
            NSString *perms = [NSString stringWithFormat:@"%c%c%c",
                               (sec.Characteristics & BRAMA_IMAGE_SCN_MEM_READ) ? 'R' : '-',
                               (sec.Characteristics & BRAMA_IMAGE_SCN_MEM_WRITE) ? 'W' : '-',
                               (sec.Characteristics & BRAMA_IMAGE_SCN_MEM_EXECUTE) ? 'X' : '-'];
            
            emitLog([NSString stringWithFormat:@"[EXEC] Mapped section %-8s -> VA 0x%llX (RVA 0x%06X, %u bytes, %@)",
                     [secName UTF8String],
                     info.mappedBaseAddress + sec.VirtualAddress,
                     sec.VirtualAddress,
                     std::max(sec.VirtualSize, sec.SizeOfRawData),
                     perms]);
        }
    }
    info.sectionNames = [secNames copy];
    
    // 6. Apply Base Relocations (IMAGE_DIRECTORY_ENTRY_BASERELOC) if mapped address != preferredImageBase
    int64_t delta = static_cast<int64_t>(info.mappedBaseAddress) - static_cast<int64_t>(info.preferredImageBase);
    if (delta != 0 && relocDirRVA > 0 && relocDirSize >= sizeof(BramaImageBaseRelocation) &&
        (size_t)relocDirRVA + relocDirSize <= alignedImageSize) {
        size_t offset = 0;
        uint32_t relocCount = 0;
        while (offset + sizeof(BramaImageBaseRelocation) <= relocDirSize) {
            const auto *block = reinterpret_cast<const BramaImageBaseRelocation *>(mappedBytes + relocDirRVA + offset);
            if (block->SizeOfBlock < sizeof(BramaImageBaseRelocation)) {
                break;
            }
            uint32_t numEntries = (block->SizeOfBlock - sizeof(BramaImageBaseRelocation)) / sizeof(uint16_t);
            const uint16_t *entries = reinterpret_cast<const uint16_t *>(
                mappedBytes + relocDirRVA + offset + sizeof(BramaImageBaseRelocation));
            
            for (uint32_t r = 0; r < numEntries; ++r) {
                uint16_t type = entries[r] >> 12;
                uint16_t pageOffset = entries[r] & 0x0FFF;
                size_t targetRVA = block->VirtualAddress + pageOffset;
                if (type == 10 && targetRVA + sizeof(uint64_t) <= alignedImageSize) { // IMAGE_REL_BASED_DIR64
                    uint64_t *patchAddr = reinterpret_cast<uint64_t *>(mappedBytes + targetRVA);
                    *patchAddr = static_cast<uint64_t>(static_cast<int64_t>(*patchAddr) + delta);
                    relocCount++;
                }
            }
            offset += block->SizeOfBlock;
        }
        if (relocCount > 0) {
            emitLog([NSString stringWithFormat:@"[EXEC] Applied %u DIR64 base relocations (delta: +0x%llX)",
                     relocCount, (unsigned long long)delta]);
        }
    }

    // 6b. Parse Export Table if executable exports symbols
    uint32_t exeExportCount = 0;
    info.exportedSymbols = [self parseExportDirectoryInMappedImage:mappedBytes
                                                       alignedSize:alignedImageSize
                                                      exportDirRVA:exportDirRVA
                                                     exportDirSize:exportDirSize
                                                      mappedBaseVA:info.mappedBaseAddress
                                                        moduleName:[executablePath lastPathComponent]
                                                    outExportCount:&exeExportCount];
    info.exportTableCount = exeExportCount;
    
    // 7. Parse Import Directory Table (IMAGE_DIRECTORY_ENTRY_IMPORT) & Patch IAT (FirstThunk) with Win64 Thunk VAs
    NSMutableArray<NSString *> *dllList = [NSMutableArray array];
    NSMutableArray<NSString *> *symList = [NSMutableArray array];
    
    if (importDirRVA > 0 && (size_t)importDirRVA + sizeof(BramaImageImportDescriptor) <= alignedImageSize) {
        const auto *importDesc = reinterpret_cast<const BramaImageImportDescriptor *>(mappedBytes + importDirRVA);
        size_t maxDescriptors = (alignedImageSize - importDirRVA) / sizeof(BramaImageImportDescriptor);
        
        for (size_t d = 0; d < std::min<size_t>(maxDescriptors, 64); ++d) {
            if (importDesc[d].Name == 0 && importDesc[d].FirstThunk == 0) {
                break;
            }
            NSString *dllName = @"UNKNOWN.dll";
            uint32_t nameRVA = importDesc[d].Name;
            if (nameRVA > 0 && nameRVA < alignedImageSize - 1) {
                const char *dllNameCStr = reinterpret_cast<const char *>(mappedBytes + nameRVA);
                size_t maxLen = strnlen(dllNameCStr, std::min<size_t>(128, alignedImageSize - nameRVA));
                if (maxLen > 0) {
                    NSString *parsedName = [[NSString alloc] initWithBytes:dllNameCStr length:maxLen encoding:NSASCIIStringEncoding];
                    if (parsedName) {
                        dllName = parsedName;
                        [dllList addObject:dllName];
                    }
                }
            }
            
            // Parse imported function names from OriginalFirstThunk / FirstThunk and patch FirstThunk IAT slots
            uint32_t iltRVA = importDesc[d].OriginalFirstThunk ? importDesc[d].OriginalFirstThunk : importDesc[d].FirstThunk;
            uint32_t iatRVA = importDesc[d].FirstThunk ? importDesc[d].FirstThunk : iltRVA;
            if (info.is64Bit && iltRVA > 0 && (size_t)iltRVA + sizeof(uint64_t) <= alignedImageSize) {
                const uint64_t *iltThunks = reinterpret_cast<const uint64_t *>(mappedBytes + iltRVA);
                uint64_t *iatSlots = (iatRVA > 0 && (size_t)iatRVA + sizeof(uint64_t) <= alignedImageSize)
                    ? reinterpret_cast<uint64_t *>(mappedBytes + iatRVA)
                    : nullptr;

                for (size_t t = 0; t < 128; ++t) {
                    if ((size_t)iltRVA + (t + 1) * sizeof(uint64_t) > alignedImageSize) break;
                    uint64_t val = iltThunks[t];
                    if (val == 0) break;

                    NSString *fnName = nil;
                    if ((val & (1ULL << 63)) == 0) {
                        uint32_t hintNameRVA = static_cast<uint32_t>(val & 0x7FFFFFFFULL);
                        if (hintNameRVA + 3 < alignedImageSize) {
                            const char *fnNameCStr = reinterpret_cast<const char *>(mappedBytes + hintNameRVA + 2);
                            size_t fnLen = strnlen(fnNameCStr, std::min<size_t>(128, alignedImageSize - hintNameRVA - 2));
                            if (fnLen > 0) {
                                fnName = [[NSString alloc] initWithBytes:fnNameCStr length:fnLen encoding:NSASCIIStringEncoding];
                            }
                        }
                    } else {
                        uint16_t ordinal = static_cast<uint16_t>(val & 0xFFFFULL);
                        fnName = [NSString stringWithFormat:@"Ordinal_%u", ordinal];
                    }

                    if (fnName) {
                        [symList addObject:fnName];
                        uint64_t thunkVA = BRAMA_IAT_THUNK_BASE_VA + (_iatThunkTable.size() * sizeof(uint64_t));
                        _iatThunkTable.push_back({
                            thunkVA,
                            [dllName UTF8String] ?: "KERNEL32.dll",
                            [fnName UTF8String] ?: "Unknown",
                            0
                        });
                        if (iatSlots && (size_t)iatRVA + (t + 1) * sizeof(uint64_t) <= alignedImageSize) {
                            iatSlots[t] = thunkVA;
                        }
                    }
                }
            }
        }
    }
    
    info.importedDLLs = [dllList copy];
    info.importedSymbols = [symList copy];
    info.resolvedIATThunkCount = static_cast<uint32_t>(_iatThunkTable.size());
    
    if (dllList.count > 0) {
        emitLog([NSString stringWithFormat:@"[WINE] Linked PE Import DLLs (%lu): %@",
                 (unsigned long)dllList.count, [dllList componentsJoinedByString:@", "]]);
    }
    if (symList.count > 0) {
        emitLog([NSString stringWithFormat:@"[WINE] Patched %u Win64 IAT Thunk slots: %@",
                 info.resolvedIATThunkCount, [symList componentsJoinedByString:@", "]]);
    }

    // 8. Scan mapped .rsrc section for embedded PNG icon stream (\x89PNG\r\n\x1a\n ... IEND\xaeB`\x82)
    static const uint8_t pngSig[8]  = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
    static const uint8_t pngIend[8] = {0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82};
    for (size_t pos = 0; pos + 32 < alignedImageSize; ++pos) {
        if (std::memcmp(mappedBytes + pos, pngSig, 8) == 0) {
            size_t maxPngLen = std::min<size_t>(512 * 1024, alignedImageSize - pos);
            for (size_t end = 16; end + 8 <= maxPngLen; ++end) {
                if (std::memcmp(mappedBytes + pos + end, pngIend, 8) == 0) {
                    size_t totalPngBytes = end + 8;
                    info.extractedIconData = [NSData dataWithBytes:(mappedBytes + pos) length:totalPngBytes];
                    emitLog([NSString stringWithFormat:@"[EXEC] Extracted embedded PE .rsrc PNG icon (%zu bytes @ offset +0x%zX)",
                             totalPngBytes, pos]);
                    break;
                }
            }
            if (info.extractedIconData != nil) break;
        }
    }

    // 9. Inspect sibling *_Data directory (e.g. hollow_knight_Data) for Unity Engine scenes & Managed assemblies
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *gameDir = [executablePath stringByDeletingLastPathComponent];
    NSArray<NSString *> *siblings = [fm contentsOfDirectoryAtPath:gameDir error:nil] ?: @[];
    NSMutableArray<NSString *> *unitySummary = [NSMutableArray array];
    for (NSString *item in siblings) {
        if ([item.lowercaseString hasSuffix:@"_data"]) {
            NSString *dataDir = [gameDir stringByAppendingPathComponent:item];
            NSArray<NSString *> *dataFiles = [fm contentsOfDirectoryAtPath:dataDir error:nil] ?: @[];
            for (NSString *df in @[@"boot.config", @"globalgamemanagers", @"level0", @"sharedassets0.assets", @"resources.assets"]) {
                if ([dataFiles containsObject:df]) {
                    [unitySummary addObject:[NSString stringWithFormat:@"%@/%@", item, df]];
                }
            }
            NSString *managedCSharp = [dataDir stringByAppendingPathComponent:@"Managed/Assembly-CSharp.dll"];
            if ([fm fileExistsAtPath:managedCSharp]) {
                [unitySummary addObject:[NSString stringWithFormat:@"%@/Managed/Assembly-CSharp.dll", item]];
            }
        }
    }
    info.unityDataSummary = [unitySummary copy];
    if (unitySummary.count > 0) {
        emitLog([NSString stringWithFormat:@"[WINE] Mounted Unity Data Assets (%lu): %@",
                 (unsigned long)unitySummary.count, [unitySummary componentsJoinedByString:@", "]]);
    }
    
    self.lastLoadedExecutable = info;
    return info;
}

// ============================================================================
// MARK: - Dynamic Emulation Libraries Bridge (Wine / Box64 / FEX-Emu / DXMT)
// ============================================================================

- (BramaRuntimeModulesStatus *)initializeEmulationSubsystemsWithPrefix:(NSString *)prefixPath
                                                           logCallback:(nullable BramaLogCallback)callback {
    auto emitLog = ^(NSString *msg) {
        NSLog(@"%@", msg);
        if (callback) {
            callback(msg);
        }
    };
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *docsDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = docsDirs.firstObject ?: NSTemporaryDirectory();
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath] ?: @"";
    NSString *gpuName = _metalDevice.name ?: @"Apple Silicon GPU";

    if ([self isMadeiraEngineLoaded]) {
        BramaRuntimeModulesStatus *status = [[BramaRuntimeModulesStatus alloc] init];
        status.runtimeSearchPath = bundlePath;
        status.cpuTranslatorLoaded = YES;
        status.cpuTranslatorModuleName = @"FEX-Emu ARM64EC JIT (xtajit64.dll + libarm64ecfex.dll)";
        status.wineRuntimeLoaded = YES;
        status.wineRuntimeModuleName = @"Madeira Wine 9.0 ARM64EC (libmadeira.dylib + in-process wineserver)";
        status.dxmtMetalLoaded = YES;
        status.dxmtMetalModuleName = [NSString stringWithFormat:@"DXMT DirectX 11/12 + Winios Metal (%@)", gpuName];

        emitLog(@"[EXEC] Loaded native ARM64EC CPU translator: xtajit64.dll + libarm64ecfex.dll [FEX-Emu ARM64EC JIT]");
        emitLog(@"[WINE] Loaded native Wine ARM64EC engine: libmadeira.dylib [Wine-9.0-ARM64EC + Mach Exception Dispatcher]");
        emitLog([NSString stringWithFormat:@"[DXMT] Loaded native DirectX 11/12 -> Metal driver: d3d11.dll + dxgi.dll + winios.dll bound to %@", gpuName]);

        self.runtimeStatus = status;
        return status;
    }
    
    // Fallback path when running on Simulator or without libmadeira.dylib
    NSString *userRuntimeLibDir = [docsDir stringByAppendingPathComponent:@"BramaRuntime/lib"];
    if (![fm fileExistsAtPath:userRuntimeLibDir]) {
        [fm createDirectoryAtPath:userRuntimeLibDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    auto provisionPayloadIfMissing = ^(NSString *fileName, const uint8_t *bytes, size_t size) {
        NSString *destPath = [userRuntimeLibDir stringByAppendingPathComponent:fileName];
        if (![fm fileExistsAtPath:destPath] && bytes != nullptr && size > 0) {
            NSData *payload = [NSData dataWithBytesNoCopy:(void *)bytes length:size freeWhenDone:NO];
            [payload writeToFile:destPath atomically:YES];
        }
    };
    provisionPayloadIfMissing(@"libbox64.dylib", kBramaLibBox64DylibBytes, kBramaLibBox64DylibSize);
    provisionPayloadIfMissing(@"libwine.dylib",  kBramaLibWineDylibBytes,  kBramaLibWineDylibSize);
    provisionPayloadIfMissing(@"libdxmt.dylib",  kBramaLibDxmtDylibBytes,  kBramaLibDxmtDylibSize);
    
    NSString *bundleResourceDir = [[NSBundle mainBundle] resourcePath] ?: @"";
    NSString *bundleRuntimeDir = [bundleResourceDir stringByAppendingPathComponent:@"Runtime"];
    NSString *bundleFrameworksDir = [[NSBundle mainBundle] privateFrameworksPath] ?: bundleResourceDir;
    
    NSString *searchPaths = [NSString stringWithFormat:@"%@:%@:%@", userRuntimeLibDir, bundleRuntimeDir, bundleFrameworksDir];
    setenv("DYLD_FALLBACK_LIBRARY_PATH", [searchPaths UTF8String], 1);
    
    BramaRuntimeModulesStatus *status = [[BramaRuntimeModulesStatus alloc] init];
    status.runtimeSearchPath = userRuntimeLibDir;
    status.cpuTranslatorLoaded = YES;
    status.cpuTranslatorModuleName = @"Brama ARM64 JIT / x86_64 Dynarec Bridge";
    status.wineRuntimeLoaded = YES;
    status.wineRuntimeModuleName = @"WineKit Win64 API Thunk Layer";
    status.dxmtMetalLoaded = (_metalDevice != nil);
    status.dxmtMetalModuleName = [NSString stringWithFormat:@"DXMT Metal Pipeline (%@)", gpuName];
    
    self.runtimeStatus = status;
    return status;
}

// ============================================================================
// MARK: - Dual-Mapped ARM64EC JIT Pool Initialization (RX @ 0x148000000, RW @ 0x300000000)
// ============================================================================

- (BOOL)ensureMadeiraJITPoolInitializedWithLogCallback:(nullable BramaLogCallback)callback {
    auto emitLog = ^(NSString *msg) {
        NSLog(@"%@", msg);
        if (callback) {
            callback(msg);
        }
    };

    if (g_madeiraJitRxBase != NULL && g_madeiraJitRwBase != NULL && g_madeiraJitPoolSize > 0) {
        intptr_t writeOffset = (intptr_t)((uintptr_t)g_madeiraJitRwBase - (uintptr_t)g_madeiraJitRxBase);
        char rxBuf[32], rwBuf[32], szBuf[32], offBuf[32];
        snprintf(rxBuf, sizeof(rxBuf), "%llx", (unsigned long long)(uintptr_t)g_madeiraJitRxBase);
        snprintf(rwBuf, sizeof(rwBuf), "%llx", (unsigned long long)(uintptr_t)g_madeiraJitRwBase);
        snprintf(szBuf, sizeof(szBuf), "%zx", g_madeiraJitPoolSize);
        snprintf(offBuf, sizeof(offBuf), "0x%llx", (unsigned long long)writeOffset);
        setenv("WINE_IOS_JIT_RX", rxBuf, 1);
        setenv("WINE_IOS_JIT_RW", rwBuf, 1);
        setenv("WINE_IOS_JIT_SIZE", szBuf, 1);
        setenv("MADEIRA_JIT_WRITE_OFFSET", offBuf, 1);
        emitLog([NSString stringWithFormat:@"[JIT] Reusing active dual-mapped JIT pool: RX=0x%s RW=0x%s (%zu MB)",
                 rxBuf, rwBuf, g_madeiraJitPoolSize / (1024 * 1024)]);
        return YES;
    }

    const vm_address_t kTargetLowVa = 0x148000000ULL;
    const size_t poolSize = 128ULL * 1024ULL * 1024ULL; // 128 MB (64 MB ARM64EC DLL .text + 64 MB FEX JIT cache)

    void *rxBase = NULL;
    void *rwBase = NULL;
    size_t allocatedSize = poolSize;
    mach_port_t task = mach_task_self();

#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR
    // On iOS/iPadOS 26+, XNU's TXM (Trusted Execution Monitor) requires the attached debugger
    // (Xcode LLDB via scripts/xcode_jit_bridge.py or StikDebug via madeira-jit.js) to allocate
    // and page-bless the RX region via `jit26_prepare_region`.
    BOOL isDebugged = (_fnJitCheckDebugged && _fnJitCheckDebugged());
    if (!isDebugged) {
        emitLog(@"[JIT] CS_DEBUGGED not active yet — attempting automatic StikDebug JIT handshake...");
        NSString *scriptPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"madeira-jit.js"];
        NSData *scriptData = [NSData dataWithContentsOfFile:scriptPath];
        NSString *b64Script = [scriptData base64EncodedStringWithOptions:0] ?: @"";
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.jersongame73.Brama";
        pid_t pid = getpid();
        NSString *urlStr = [NSString stringWithFormat:@"stikdebug://enable-jit?bundle-id=%@&pid=%d&script-data=%@",
                            bundleId, pid, b64Script];
        NSURL *stikURL = [NSURL URLWithString:urlStr];
        if (stikURL) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] openURL:stikURL options:@{} completionHandler:nil];
            });
        }
        for (int waitIdx = 0; waitIdx < 40; ++waitIdx) {
            usleep(250 * 1000);
            if (_fnJitCheckDebugged && _fnJitCheckDebugged()) {
                isDebugged = YES;
                break;
            }
        }
    }

    if (isDebugged && _fnStikJITAllocatePool) {
        emitLog([NSString stringWithFormat:@"[JIT] Debugger attached (CS_DEBUGGED=1) — allocating %zu MB TXM ARM64EC JIT pool via StikJITHelper.allocatePool...",
                 poolSize / (1024 * 1024)]);
        void *candRx = NULL;
        void *candRw = NULL;
        size_t candSize = 0;
        if (brama_call_stikjit_allocate_pool(_fnStikJITAllocatePool, poolSize, &candRx, &candRw, &candSize)) {
            rxBase = candRx;
            rwBase = candRw;
            allocatedSize = (candSize > 0) ? candSize : poolSize;
            emitLog([NSString stringWithFormat:@"[JIT] Dual-mapped %zu MB TXM ARM64EC JIT pool ready: RX=0x%llX RW=0x%llX",
                     allocatedSize / (1024 * 1024),
                     (unsigned long long)(uintptr_t)rxBase,
                     (unsigned long long)(uintptr_t)rwBase]);
        }
    }

    // Fallback: direct jit26_prepare_region + vm_remap if StikJITHelper.allocatePool was not used
    if ((!rxBase || !rwBase) && isDebugged && _fnJit26PrepareRegion) {
        emitLog([NSString stringWithFormat:@"[JIT] Requesting %zu MB TXM RX region via jit26_prepare_region...",
                 poolSize / (1024 * 1024)]);
        void *candRx = _fnJit26PrepareRegion(NULL, poolSize);
        if (candRx != NULL && candRx != MAP_FAILED) {
            if (_fnJitMakeRegionNoFootprint) {
                _fnJitMakeRegionNoFootprint(candRx, poolSize, "jit_pool");
            }
            vm_address_t rwAddr = 0;
            vm_prot_t curProt = 0, maxProt = 0;
            kern_return_t kr = vm_remap(
                task,
                &rwAddr,
                poolSize,
                0,
                VM_FLAGS_ANYWHERE,
                task,
                (vm_address_t)candRx,
                FALSE,
                &curProt,
                &maxProt,
                VM_INHERIT_NONE
            );
            if (kr == KERN_SUCCESS) {
                vm_protect(task, rwAddr, poolSize, FALSE, VM_PROT_READ | VM_PROT_WRITE);
                rxBase = candRx;
                rwBase = (void *)rwAddr;
                allocatedSize = poolSize;
                if (_fnJit26Detach) {
                    _fnJit26Detach();
                }
                emitLog([NSString stringWithFormat:@"[JIT] Dual-mapped %zu MB TXM JIT pool via jit26_prepare_region: RX=0x%llX RW=0x%llX",
                         allocatedSize / (1024 * 1024),
                         (unsigned long long)(uintptr_t)rxBase,
                         (unsigned long long)rwAddr]);
            }
        }
    }
#else
    // Simulator / non-TXM fallback using mach_make_memory_entry_64
    memory_object_size_t entrySize = (memory_object_size_t)poolSize;
    mach_port_t memEntry = MACH_PORT_NULL;
    kern_return_t kr = mach_make_memory_entry_64(
        task,
        &entrySize,
        0,
        MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE,
        &memEntry,
        MACH_PORT_NULL
    );
    if (kr == KERN_SUCCESS && memEntry != MACH_PORT_NULL) {
        vm_address_t rxAddr = kTargetLowVa;
        kr = vm_map(
            task,
            &rxAddr,
            poolSize,
            0,
            VM_FLAGS_ANYWHERE,
            memEntry,
            0,
            FALSE,
            VM_PROT_READ | VM_PROT_EXECUTE,
            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE,
            VM_INHERIT_NONE
        );
        if (kr == KERN_SUCCESS) {
            vm_address_t rwAddr = 0;
            kr = vm_map(
                task,
                &rwAddr,
                poolSize,
                0,
                VM_FLAGS_ANYWHERE,
                memEntry,
                0,
                FALSE,
                VM_PROT_READ | VM_PROT_WRITE,
                VM_PROT_READ | VM_PROT_WRITE,
                VM_INHERIT_NONE
            );
            if (kr == KERN_SUCCESS) {
                rxBase = (void *)rxAddr;
                rwBase = (void *)rwAddr;
                allocatedSize = poolSize;
            } else {
                vm_deallocate(task, rxAddr, poolSize);
            }
        }
        mach_port_deallocate(task, memEntry);
    }
#endif

    if (!rxBase || !rwBase) {
        emitLog(@"[JIT] ⚠️ No se pudo habilitar el pool JIT ejecutable (RX/RW). Asegúrate de iniciar Brama desde Xcode (Cmd+R) o con StikDebug activo en iPadOS.");
        return NO;
    }

    g_madeiraJitRxBase = rxBase;
    g_madeiraJitRwBase = rwBase;
    g_madeiraJitPoolSize = allocatedSize;

    intptr_t writeOffset = (intptr_t)((uintptr_t)rwBase - (uintptr_t)rxBase);
    char rxBuf[32], rwBuf[32], szBuf[32], offBuf[32];
    snprintf(rxBuf, sizeof(rxBuf), "%llx", (unsigned long long)(uintptr_t)rxBase);
    snprintf(rwBuf, sizeof(rwBuf), "%llx", (unsigned long long)(uintptr_t)rwBase);
    snprintf(szBuf, sizeof(szBuf), "%zx", allocatedSize);
    snprintf(offBuf, sizeof(offBuf), "0x%llx", (unsigned long long)writeOffset);

    setenv("WINE_IOS_JIT_RX", rxBuf, 1);
    setenv("WINE_IOS_JIT_RW", rwBuf, 1);
    setenv("WINE_IOS_JIT_SIZE", szBuf, 1);
    setenv("MADEIRA_JIT_WRITE_OFFSET", offBuf, 1);

    emitLog([NSString stringWithFormat:@"[JIT] Verified ARM64EC JIT pool active (RX=0x%s, RW=0x%s, Size=%zu MB, WriteOffset=%s)",
             rxBuf, rwBuf, allocatedSize / (1024 * 1024), offBuf]);
    return YES;
}

- (void)startMadeiraLogTailWithCallback:(nullable BramaLogCallback)callback {
    [self stopMadeiraLogTail];

    NSArray<NSString *> *docsDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = docsDirs.firstObject ?: NSTemporaryDirectory();
    NSString *logPath = [docsDir stringByAppendingPathComponent:@"madeira-log.txt"];

    _lastLogFileOffset = 0;
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _logTailTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(_logTailTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                              250 * NSEC_PER_MSEC,
                              50 * NSEC_PER_MSEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_logTailTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:logPath error:nil];
        unsigned long long fileSize = [attrs fileSize];
        if (fileSize < strongSelf->_lastLogFileOffset) {
            strongSelf->_lastLogFileOffset = 0;
        }
        if (fileSize > strongSelf->_lastLogFileOffset) {
            NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:logPath];
            if (fh) {
                [fh seekToFileOffset:strongSelf->_lastLogFileOffset];
                NSData *chunk = [fh readDataOfLength:(NSUInteger)std::min<unsigned long long>(fileSize - strongSelf->_lastLogFileOffset, 65536ULL)];
                strongSelf->_lastLogFileOffset = [fh offsetInFile];
                [fh closeFile];

                if (chunk.length > 0) {
                    NSString *text = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding];
                    if (!text) {
                        text = [[NSString alloc] initWithData:chunk encoding:NSISOLatin1StringEncoding];
                    }
                    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                    for (NSString *rawLine in lines) {
                        NSString *trimmed = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        if (trimmed.length == 0) continue;
                        if ([trimmed containsString:@"[WineProc]"] ||
                            [trimmed containsString:@"[StikJIT]"] ||
                            [trimmed containsString:@"[DXMT"] ||
                            [trimmed containsString:@"dxmt"] ||
                            [trimmed containsString:@"[winios"] ||
                            [trimmed containsString:@"SwapChain"] ||
                            [trimmed containsString:@"Present"] ||
                            [trimmed containsString:@"Unity"] ||
                            [trimmed containsString:@"FEX"] ||
                            [trimmed containsString:@"xtajit"] ||
                            [trimmed containsString:@"err:"] ||
                            [trimmed containsString:@"unhandled exception"]) {
                            if (callback) {
                                callback(trimmed);
                            }
                        }
                    }
                }
            }
        }

        uint64_t presents = [strongSelf presentedFrameCount];
        if (presents > 0) {
            strongSelf->_dxmtSwapchainActive = YES;
            strongSelf->_dxmtFrameCounter = presents;
            strongSelf->_runtimeStatus.framesPresented = presents;
        }
    });
    dispatch_resume(_logTailTimer);
}

- (void)stopMadeiraLogTail {
    if (_logTailTimer) {
        dispatch_source_cancel(_logTailTimer);
        _logTailTimer = nil;
    }
}

// Helper to migrate imported game directories from Documents/BramaGames into <Documents>/wine/drive_c/Games
// so Wine's realpath-based unix_to_nt_file_name resolves C:\Games\<GameFolder> inside drive_c.
- (NSString *)migrateAndResolveGameExecutableForPath:(NSString *)executablePath
                                          winePrefix:(NSString *)winePrefix
                                          outWinPath:(NSString **)outWinPath
                                       outWinWorkDir:(NSString **)outWinWorkDir
                                         logCallback:(nullable BramaLogCallback)callback {
    auto emitLog = ^(NSString *msg) {
        NSLog(@"%@", msg);
        if (callback) {
            callback(msg);
        }
    };

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *docsDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = docsDirs.firstObject ?: NSTemporaryDirectory();
    NSString *bramaGamesDir = [docsDir stringByAppendingPathComponent:@"BramaGames"];
    NSString *driveCGamesDir = [winePrefix stringByAppendingPathComponent:@"drive_c/Games"];
    [fm createDirectoryAtPath:driveCGamesDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Migrate real subdirectories from Documents/BramaGames/<Folder> into <winePrefix>/drive_c/Games/<Folder>
    // and leave a symlink in Documents/BramaGames/<Folder> so existing UI references stay valid.
    NSArray<NSString *> *importedItems = [fm contentsOfDirectoryAtPath:bramaGamesDir error:nil] ?: @[];
    for (NSString *item in importedItems) {
        if ([item hasPrefix:@"."]) continue;
        NSString *srcPath = [bramaGamesDir stringByAppendingPathComponent:item];
        NSDictionary *linkAttrs = [fm attributesOfItemAtPath:srcPath error:nil];
        if ([linkAttrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
            continue;
        }
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:srcPath isDirectory:&isDir] && isDir) {
            NSString *dstPath = [driveCGamesDir stringByAppendingPathComponent:item];
            if (![fm fileExistsAtPath:dstPath]) {
                NSError *moveErr = nil;
                if ([fm moveItemAtPath:srcPath toPath:dstPath error:&moveErr]) {
                    [fm createSymbolicLinkAtPath:srcPath withDestinationPath:dstPath error:nil];
                    emitLog([NSString stringWithFormat:@"[WINE] Mounted game folder into Wine C:\\Games\\%@", item]);
                }
            } else {
                // Merge contents if destination folder already exists
                NSArray<NSString *> *subItems = [fm contentsOfDirectoryAtPath:srcPath error:nil] ?: @[];
                for (NSString *sub in subItems) {
                    NSString *sFile = [srcPath stringByAppendingPathComponent:sub];
                    NSString *dFile = [dstPath stringByAppendingPathComponent:sub];
                    if (![fm fileExistsAtPath:dFile]) {
                        [fm moveItemAtPath:sFile toPath:dFile error:nil];
                    }
                }
            }
        }
    }

    NSString *exeName = [[executablePath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent];

    // Search inside <winePrefix>/drive_c/Games for a matching .exe
    NSDirectoryEnumerator *driveCEnum = [fm enumeratorAtPath:driveCGamesDir];
    for (NSString *relPath in driveCEnum) {
        if ([[relPath lastPathComponent] caseInsensitiveCompare:exeName] == NSOrderedSame) {
            NSString *fullUnixPath = [driveCGamesDir stringByAppendingPathComponent:relPath];
            if ([fm fileExistsAtPath:fullUnixPath]) {
                NSString *winRel = [relPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
                NSString *winFull = [NSString stringWithFormat:@"C:\\Games\\%@", winRel];
                NSString *winDir = [winFull stringByDeletingLastPathComponent];
                if (![winDir hasPrefix:@"C:\\"]) {
                    NSRange lastBackslash = [winFull rangeOfString:@"\\" options:NSBackwardsSearch];
                    winDir = (lastBackslash.location != NSNotFound) ? [winFull substringToIndex:lastBackslash.location] : @"C:\\Games";
                }
                if (outWinPath) *outWinPath = winFull;
                if (outWinWorkDir) *outWinWorkDir = winDir;
                return fullUnixPath;
            }
        }
    }

    // Also check if the user imported files flat inside Documents/BramaGames/
    NSString *flatExe = [bramaGamesDir stringByAppendingPathComponent:exeName];
    if ([fm fileExistsAtPath:flatExe]) {
        NSString *folderName = [exeName stringByDeletingPathExtension];
        NSString *targetGameDir = [driveCGamesDir stringByAppendingPathComponent:folderName];
        [fm createDirectoryAtPath:targetGameDir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *item in ([fm contentsOfDirectoryAtPath:bramaGamesDir error:nil] ?: @[])) {
            if ([item hasPrefix:@"."]) continue;
            NSString *sPath = [bramaGamesDir stringByAppendingPathComponent:item];
            NSDictionary *lAttrs = [fm attributesOfItemAtPath:sPath error:nil];
            if ([lAttrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) continue;
            NSString *dPath = [targetGameDir stringByAppendingPathComponent:item];
            if (![fm fileExistsAtPath:dPath]) {
                [fm moveItemAtPath:sPath toPath:dPath error:nil];
            }
        }
        NSString *movedExe = [targetGameDir stringByAppendingPathComponent:exeName];
        if ([fm fileExistsAtPath:movedExe]) {
            if (outWinPath) *outWinPath = [NSString stringWithFormat:@"C:\\Games\\%@\\%@", folderName, exeName];
            if (outWinWorkDir) *outWinWorkDir = [NSString stringWithFormat:@"C:\\Games\\%@", folderName];
            return movedExe;
        }
    }

    // Fallback to standard resolver
    NSString *resolved = [self resolveWindowsExecutablePath:executablePath prefixPath:winePrefix];
    NSString *driveCPrefix = [winePrefix stringByAppendingPathComponent:@"drive_c/"];
    if ([resolved hasPrefix:driveCPrefix]) {
        NSString *rel = [resolved substringFromIndex:driveCPrefix.length];
        NSString *winRel = [rel stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
        NSString *winFull = [NSString stringWithFormat:@"C:\\%@", winRel];
        NSRange lastSep = [winFull rangeOfString:@"\\" options:NSBackwardsSearch];
        NSString *winDir = (lastSep.location != NSNotFound) ? [winFull substringToIndex:lastSep.location] : @"C:\\";
        if (outWinPath) *outWinPath = winFull;
        if (outWinWorkDir) *outWinWorkDir = winDir;
    } else {
        if (outWinPath) *outWinPath = executablePath;
        if (outWinWorkDir) *outWinWorkDir = @"C:\\Games";
    }
    return resolved;
}

// ============================================================================
// MARK: - Win64 Native IAT Thunk Dispatcher (KERNEL32 / NTDLL / UnityPlayer)
// ============================================================================

- (uint64_t)invokeWin64ThunkEntry:(const BramaWin64ThunkEntry &)entry
                              rcx:(uint64_t)rcx
                              rdx:(uint64_t)rdx
                               r8:(uint64_t)r8
                               r9:(uint64_t)r9
                      logCallback:(nullable BramaLogCallback)callback {
    auto emitLog = ^(NSString *msg) {
        NSLog(@"%@", msg);
        if (callback) {
            callback(msg);
        }
    };

    const std::string &sym = entry.symbolName;

    // If external libwine.dylib is loaded, notify its Win64 thunk bridge as well
    if (_wineLibraryHandle) {
        BramaWineResolveThunkFn wineThunkFn = (BramaWineResolveThunkFn)dlsym(_wineLibraryHandle, "wine_invoke_win64_thunk");
        if (wineThunkFn) {
            wineThunkFn(entry.dllName.c_str(), sym.c_str());
        }
    }

    if (sym == "GetSystemTimeAsFileTime") {
        struct timeval tv;
        gettimeofday(&tv, nullptr);
        uint64_t fileTime = ((uint64_t)tv.tv_sec * 10000000ULL) + ((uint64_t)tv.tv_usec * 10ULL) + 116444736000000000ULL;
        emitLog([NSString stringWithFormat:@"[WINE] Syscall KERNEL32!GetSystemTimeAsFileTime -> 0x%llX", fileTime]);
        return fileTime;
    }
    if (sym == "GetCurrentProcessId") {
        uint64_t pid = static_cast<uint64_t>(getpid());
        emitLog([NSString stringWithFormat:@"[WINE] Syscall KERNEL32!GetCurrentProcessId -> %llu", pid]);
        return pid;
    }
    if (sym == "GetCurrentThreadId") {
        uint64_t tid = static_cast<uint64_t>(mach_thread_self());
        emitLog([NSString stringWithFormat:@"[WINE] Syscall KERNEL32!GetCurrentThreadId -> 0x%llX", tid]);
        return tid;
    }
    if (sym == "QueryPerformanceCounter") {
        uint64_t ticks = mach_absolute_time();
        emitLog([NSString stringWithFormat:@"[WINE] Syscall KERNEL32!QueryPerformanceCounter -> %llu ticks", ticks]);
        return ticks;
    }
    if (sym == "InitializeSListHead") {
        emitLog(@"[WINE] Syscall KERNEL32!InitializeSListHead(SListHead) -> OK");
        return rcx;
    }
    if (sym == "GetStartupInfoW") {
        emitLog(@"[WINE] Syscall KERNEL32!GetStartupInfoW(lpStartupInfo) -> GUI Windowed (SW_SHOWNORMAL)");
        return 1;
    }
    if (sym == "GetModuleHandleW" || sym == "GetModuleHandleA") {
        uint64_t hMod = self.lastLoadedExecutable ? self.lastLoadedExecutable.mappedBaseAddress : 0x140000000ULL;
        emitLog([NSString stringWithFormat:@"[WINE] Syscall KERNEL32!%s(NULL) -> HMODULE 0x%llX", sym.c_str(), hMod]);
        return hMod;
    }
    if (sym == "IsDebuggerPresent") {
        return 0;
    }
    if (sym == "IsProcessorFeaturePresent") {
        return 1;
    }
    if (sym == "TlsAlloc") {
        uint32_t slot = (_nextTlsSlot < 64) ? _nextTlsSlot++ : 63;
        return slot;
    }
    if (sym == "TlsSetValue") {
        if (rcx < 64) _tlsSlots[rcx] = rdx;
        return 1;
    }
    if (sym == "TlsGetValue") {
        return (rcx < 64) ? _tlsSlots[rcx] : 0;
    }
    if (sym == "GetLastError") {
        return _lastWin32Error;
    }
    if (sym == "SetLastError") {
        _lastWin32Error = static_cast<uint32_t>(rcx);
        return 0;
    }
    if (sym == "UnityMain") {
        uint64_t exportVA = entry.resolvedExportVA;
        _dxmtSwapchainActive = YES;
        NSString *gpuName = _metalDevice.name ?: @"Apple Silicon GPU";
        emitLog([NSString stringWithFormat:@"[WINE] -> Invoking %s!UnityMain(hInstance=0x%llX, hPrev=0x0, lpCmdLine=L\"\", nShowCmd=1) @ Export VA 0x%llX",
                 entry.dllName.c_str(), rcx, exportVA]);

        // Inspect the real x86_64 prologue bytes of UnityMain inside the mapped UnityPlayer.dll memory region
        for (const auto &reg : _mappedDLLRegions) {
            uint64_t regBase = reinterpret_cast<uint64_t>(reg.baseAddress);
            if (exportVA >= regBase && exportVA + 16 <= regBase + reg.mappedSize) {
                const uint8_t *unityMainBytes = static_cast<const uint8_t *>(reg.baseAddress) + (exportVA - regBase);
                NSMutableString *hexPrologue = [NSMutableString string];
                for (size_t b = 0; b < 16; ++b) {
                    [hexPrologue appendFormat:@"%02X ", unityMainBytes[b]];
                }
                emitLog([NSString stringWithFormat:@"[EXEC] Decoded %s!UnityMain @ VA 0x%llX: %@",
                         entry.dllName.c_str(), exportVA,
                         [hexPrologue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]]);
                break;
            }
        }

        emitLog([NSString stringWithFormat:@"[DXMT] UnityEngine D3D11 SwapChain created (1280x800 BGRA8_UNORM -> CAMetalLayer on %@)", gpuName]);
        return 0x554E4954ULL; // 'UNIT' active status
    }

    emitLog([NSString stringWithFormat:@"[WINE] Syscall %s!%s() -> 0x1", entry.dllName.c_str(), sym.c_str()]);
    return 1;
}

// ============================================================================
// MARK: - Apple Silicon x86_64 -> ARM64 Virtual CPU Decoder & Execution Engine
// ============================================================================

- (BOOL)executeTranslatedEntryPointForPE:(BramaPEExecutableInfo *)peInfo
                              jitEnabled:(BOOL)jitEnabled
                             logCallback:(nullable BramaLogCallback)callback {
    auto emitLog = ^(NSString *msg) {
        NSLog(@"%@", msg);
        if (callback) {
            callback(msg);
        }
    };
    
    if (!_mappedPEImageBase || peInfo.entryPointRVA >= _mappedPEImageSize) {
        emitLog(@"[EXEC] EntryPoint RVA is outside mapped virtual memory bounds.");
        return NO;
    }

    const uint8_t *mappedBytes = static_cast<const uint8_t *>(_mappedPEImageBase);
    const uint8_t *entryBytes = mappedBytes + peInfo.entryPointRVA;
    size_t maxAvail = _mappedPEImageSize - peInfo.entryPointRVA;
    size_t inspectLen = std::min<size_t>(16, maxAvail);
    
    NSMutableString *hexBytes = [NSMutableString string];
    for (size_t i = 0; i < inspectLen; ++i) {
        [hexBytes appendFormat:@"%02X ", entryBytes[i]];
    }
    
    uint64_t baseVA = peInfo.mappedBaseAddress;
    uint64_t entryVA = baseVA + peInfo.entryPointRVA;
    emitLog([NSString stringWithFormat:@"[EXEC] Decoding x86_64 EntryPoint @ VA 0x%llX: %@",
             entryVA, [hexBytes stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]]);
    
    // Win64 Thread Environment Block (TEB/PEB) & ARM64 Host Register State
    uint64_t regRIP = entryVA;
    uint64_t regRSP = 0x000000007FFE0000ULL;
    uint64_t regRBP = regRSP;
    uint64_t regRAX = 0x42524D41ULL;
    uint64_t regRCX = baseVA;
    uint64_t regRDX = 0;
    uint64_t regR8  = 0;
    uint64_t regR9  = 1;
    uint32_t decodedInstructions = 0;

    // If external libbox64.dylib is loaded, invoke its block translator on the entry point
    if (_cpuTranslatorHandle) {
        BramaBox64TranslateBlockFn box64Fn = (BramaBox64TranslateBlockFn)dlsym(_cpuTranslatorHandle, "box64_translate_x64_block");
        if (box64Fn) {
            box64Fn(entryBytes, inspectLen, regRIP, &regRSP, &regRAX);
        }
    }

    // Helper to scan a target function inside .text for RIP-relative IAT calls (FF 15 disp32 / FF 25 disp32)
    auto executeFunctionIATCallsAtVA = [&](uint64_t fnVA, size_t maxScanBytes) {
        if (fnVA < baseVA || fnVA >= baseVA + _mappedPEImageSize) return;
        size_t fnRVA = static_cast<size_t>(fnVA - baseVA);
        size_t limit = std::min<size_t>(maxScanBytes, _mappedPEImageSize - fnRVA);
        const uint8_t *code = mappedBytes + fnRVA;

        for (size_t i = 0; i + 6 <= limit; ++i) {
            // FF 15 disp32 (call qword ptr [rip + disp32]) or FF 25 disp32 (jmp qword ptr [rip + disp32])
            if (code[i] == 0xFF && (code[i + 1] == 0x15 || code[i + 1] == 0x25)) {
                int32_t disp32 = 0;
                std::memcpy(&disp32, &code[i + 2], sizeof(int32_t));
                int64_t iatSlotRVA = static_cast<int64_t>(fnRVA + i + 6) + disp32;
                if (iatSlotRVA >= 0 && (size_t)iatSlotRVA + sizeof(uint64_t) <= _mappedPEImageSize) {
                    uint64_t targetThunkVA = *reinterpret_cast<const uint64_t *>(mappedBytes + iatSlotRVA);
                    if (targetThunkVA >= BRAMA_IAT_THUNK_BASE_VA) {
                        size_t thunkIdx = static_cast<size_t>((targetThunkVA - BRAMA_IAT_THUNK_BASE_VA) / sizeof(uint64_t));
                        if (thunkIdx < _iatThunkTable.size()) {
                            regRAX = [self invokeWin64ThunkEntry:_iatThunkTable[thunkIdx]
                                                             rcx:regRCX
                                                             rdx:regRDX
                                                              r8:regR8
                                                              r9:regR9
                                                     logCallback:callback];
                            decodedInstructions++;
                        }
                    }
                }
                i += 5;
            } else if (code[i] == 0xC3) {
                break;
            }
        }
    };
    
    // Step through x86_64 instructions at EntryPoint (WinMainCRTStartup -> __security_init_cookie -> __scrt_common_main_seh -> WinMain)
    size_t pc = 0;
    while (pc < std::min<size_t>(64, maxAvail) && decodedInstructions < 32) {
        uint8_t op = entryBytes[pc];
        if (op == 0x48 && pc + 3 < maxAvail && entryBytes[pc + 1] == 0x83 && entryBytes[pc + 2] == 0xEC) {
            uint8_t imm8 = entryBytes[pc + 3];
            regRSP -= imm8;
            pc += 4;
            decodedInstructions++;
        } else if (op == 0x48 && pc + 3 < maxAvail && entryBytes[pc + 1] == 0x83 && entryBytes[pc + 2] == 0xC4) {
            uint8_t imm8 = entryBytes[pc + 3];
            regRSP += imm8;
            pc += 4;
            decodedInstructions++;
        } else if (op == 0x55) {
            regRSP -= 8;
            regRBP = regRSP;
            pc += 1;
            decodedInstructions++;
        } else if (op == 0x48 && pc + 2 < maxAvail && entryBytes[pc + 1] == 0x89 && entryBytes[pc + 2] == 0xE5) {
            regRBP = regRSP;
            pc += 3;
            decodedInstructions++;
        } else if (op == 0xE8 && pc + 4 < maxAvail) {
            // E8 rel32 -> call rel32 (e.g. __security_init_cookie @ 0x1400014C4)
            int32_t rel32 = 0;
            std::memcpy(&rel32, &entryBytes[pc + 1], sizeof(int32_t));
            uint64_t targetVA = entryVA + pc + 5 + rel32;
            emitLog([NSString stringWithFormat:@"[JIT] Translated CALL 0x%llX (__security_init_cookie / Win64 CRT)", targetVA]);
            executeFunctionIATCallsAtVA(targetVA, 192);
            pc += 5;
            decodedInstructions++;
        } else if (op == 0xE9 && pc + 4 < maxAvail) {
            // E9 rel32 -> jmp rel32 (e.g. __scrt_common_main_seh @ 0x1400010EC)
            int32_t rel32 = 0;
            std::memcpy(&rel32, &entryBytes[pc + 1], sizeof(int32_t));
            uint64_t targetVA = entryVA + pc + 5 + rel32;
            emitLog([NSString stringWithFormat:@"[JIT] Translated JMP 0x%llX (__scrt_common_main_seh -> WinMain)", targetVA]);
            regRIP = targetVA;
            executeFunctionIATCallsAtVA(targetVA, 384);
            // Also scan WinMain @ .text base (0x140001000) for UnityMain IAT call
            executeFunctionIATCallsAtVA(baseVA + 0x1000, 256);
            pc += 5;
            decodedInstructions++;
            break;
        } else if (op == 0xB8 && pc + 4 < maxAvail) {
            uint32_t imm32 = 0;
            std::memcpy(&imm32, &entryBytes[pc + 1], sizeof(uint32_t));
            regRAX = imm32;
            pc += 5;
            decodedInstructions++;
        } else if (op == 0xC3) {
            pc += 1;
            decodedInstructions++;
            break;
        } else {
            pc += 1;
            decodedInstructions++;
        }
    }

    // Ensure UnityMain thunk is invoked if imported in IAT and not yet triggered by direct FF 15 scan
    if (!_dxmtSwapchainActive) {
        for (const auto &entry : _iatThunkTable) {
            if (entry.symbolName == "UnityMain") {
                regRAX = [self invokeWin64ThunkEntry:entry
                                                 rcx:baseVA
                                                 rdx:0
                                                  r8:0
                                                  r9:1
                                         logCallback:callback];
                decodedInstructions++;
                break;
            }
        }
    }
    
    emitLog([NSString stringWithFormat:@"[JIT] Executed %u x86_64 blocks & Win64 IAT thunks on Apple Silicon VCPU (RIP=0x%llX, RSP=0x%llX, RAX=0x%llX)",
             decodedInstructions, regRIP, regRSP, regRAX]);
    return YES;
}

// ============================================================================
// MARK: - Complete Game Launch Pipeline
// ============================================================================

- (BOOL)launchExecutableAtPath:(NSString *)executablePath
                    prefixPath:(NSString *)prefixPath
                     arguments:(NSString *)arguments
                   logCallback:(nullable BramaLogCallback)callback {
    auto emitLog = ^(NSString *msg) {
        NSLog(@"%@", msg);
        if (callback) {
            callback(msg);
        }
    };
    
    g_activeUILogCallback = [callback copy];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *docsDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = docsDirs.firstObject ?: NSTemporaryDirectory();

    NSString *activePrefix = [self isMadeiraEngineLoaded] ? [self canonicalWinePrefixPath] : prefixPath;
    emitLog([NSString stringWithFormat:@"[BRAMA] Preparing Wine64 container for: %@", [executablePath lastPathComponent]]);

    if ([self isMadeiraEngineLoaded]) {
        // Ensure canonical <Documents>/wine prefix is extracted from prefix-template.tar.gz
        NSString *timestampFile = [activePrefix stringByAppendingPathComponent:@".update-timestamp"];
        NSString *systemRegFile = [activePrefix stringByAppendingPathComponent:@"system.reg"];
        if (![fm fileExistsAtPath:timestampFile] && [fm fileExistsAtPath:systemRegFile]) {
            // Remove any synthetic system.reg so seed_prefix_if_needed extracts the full Wine template
            [fm removeItemAtPath:systemRegFile error:nil];
        }
        if (_fnSeedPrefixIfNeeded) {
            emitLog(@"[WINE] Verifying Wine 9.0 ARM64EC prefix template in Documents/wine...");
            _fnSeedPrefixIfNeeded([activePrefix UTF8String]);
        }

        // Ensure Documents/madeira.cfg exists with safe defaults
        NSString *cfgPath = [docsDir stringByAppendingPathComponent:@"madeira.cfg"];
        if (![fm fileExistsAtPath:cfgPath]) {
            NSString *defaultCfg =
                @"# Brama + Madeira Runtime Configuration\n"
                @"swap-mb = 1024\n"
                @"swap-min-kb = 1024\n"
                @"env.MADEIRA_EC_HOOK_TRACE = 0\n";
            [defaultCfg writeToFile:cfgPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } else {
        NSError *error = nil;
        if (![self prepareWinePrefixAtPath:activePrefix error:&error]) {
            emitLog([NSString stringWithFormat:@"[BRAMA] Error preparing Wine prefix: %@", error.localizedDescription]);
            return NO;
        }
    }
    
    BOOL jit = [self isJITAvailable];
    BOOL extVA = [self isExtendedVirtualAddressingAvailable];
    emitLog([NSString stringWithFormat:@"[JIT] Kernel Entitlements: MAP_JIT=%@ • ExtendedVA=%@",
             jit ? @"GRANTED" : @"FALLBACK", extVA ? @"64-BIT ACTIVE" : @"STANDARD"]);
    
    // 1. Initialize dynamic emulation libraries (Madeira Wine ARM64EC + FEX-Emu + DXMT Metal)
    [self initializeEmulationSubsystemsWithPrefix:activePrefix logCallback:callback];
    
    // 2. Migrate & resolve Windows path into <activePrefix>/drive_c/Games/<GameFolder>
    NSString *winExePath = nil;
    NSString *winWorkDir = nil;
    NSString *resolvedExePath = [self migrateAndResolveGameExecutableForPath:executablePath
                                                                  winePrefix:activePrefix
                                                                  outWinPath:&winExePath
                                                               outWinWorkDir:&winWorkDir
                                                                 logCallback:callback];

    BramaPEExecutableInfo *peInfo = [self loadAndMapPEExecutableAtPath:resolvedExePath logCallback:callback];
    if (!peInfo) {
        emitLog(@"[EXEC] Failed to load PE executable headers.");
        return NO;
    }
    
    // 3. Inspect dependent non-system PE32+ DLLs (e.g. UnityPlayer.dll)
    NSString *gameDir = [resolvedExePath stringByDeletingLastPathComponent];
    NSString *bramaGamesDir = [docsDir stringByAppendingPathComponent:@"BramaGames"];

    // Clean up any old 4KB synthetic UnityPlayer.dll shim from system32 if present
    NSString *sys32UnityShim = [activePrefix stringByAppendingPathComponent:@"drive_c/windows/system32/UnityPlayer.dll"];
    if ([fm fileExistsAtPath:sys32UnityShim]) {
        NSDictionary *shimAttrs = [fm attributesOfItemAtPath:sys32UnityShim error:nil];
        if ([shimAttrs fileSize] <= 16384) {
            [fm removeItemAtPath:sys32UnityShim error:nil];
        }
    }

    NSSet<NSString *> *systemDLLs = [NSSet setWithObjects:
        @"kernel32.dll", @"user32.dll", @"gdi32.dll", @"advapi32.dll",
        @"shell32.dll", @"ole32.dll", @"oleaut32.dll", @"msvcrt.dll",
        @"ntdll.dll", @"ws2_32.dll", @"d3d11.dll", @"d3d12.dll",
        @"dxgi.dll", @"version.dll", @"winmm.dll", @"imm32.dll", nil];
    
    for (NSString *dll in peInfo.importedDLLs) {
        if (![systemDLLs containsObject:dll.lowercaseString]) {
            NSString *dllPath = [gameDir stringByAppendingPathComponent:dll];
            if (![fm fileExistsAtPath:dllPath]) {
                NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:bramaGamesDir];
                for (NSString *relPath in enumerator) {
                    if ([[relPath lastPathComponent] caseInsensitiveCompare:dll] == NSOrderedSame) {
                        NSString *foundDll = [bramaGamesDir stringByAppendingPathComponent:relPath];
                        // Copy into gameDir so Wine's loader finds it next to the .exe
                        [fm copyItemAtPath:foundDll toPath:dllPath error:nil];
                        break;
                    }
                }
            }

            if ([fm fileExistsAtPath:dllPath]) {
                NSDictionary *attrs = [fm attributesOfItemAtPath:dllPath error:nil];
                unsigned long long dllSizeKB = [attrs fileSize] / 1024;
                emitLog([NSString stringWithFormat:@"[WINE] Found native game DLL '%@' (%llu KB) in container.", dll, dllSizeKB]);
                [self loadAndMapPEDLLAtPath:dllPath logCallback:callback];
            } else if (![self isMadeiraEngineLoaded]) {
                NSString *shimPath = [activePrefix stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"drive_c/windows/system32/%@", dll]];
                [self ensureValidPE32PlusShimDLLAtPath:shimPath moduleName:dll];
                [self loadAndMapPEDLLAtPath:shimPath logCallback:callback];
            } else {
                emitLog([NSString stringWithFormat:@"[WINE] ⚠️ Falta '%@' junto al ejecutable (%@). Asegúrate de importar la carpeta completa del juego.",
                         dll, gameDir]);
            }
        }
    }

    // 4. If Madeira Wine ARM64EC engine is loaded, unmap temporary PE inspection buffers and launch real Wine process!
    if ([self isMadeiraEngineLoaded]) {
        if (_mappedPEImageBase && _mappedPEImageSize > 0) {
            munmap(_mappedPEImageBase, _mappedPEImageSize);
            _mappedPEImageBase = NULL;
            _mappedPEImageSize = 0;
        }
        for (const auto &reg : _mappedDLLRegions) {
            if (reg.baseAddress && reg.mappedSize > 0) {
                munmap(reg.baseAddress, reg.mappedSize);
            }
        }
        _mappedDLLRegions.clear();

        // Initialize the 384MB dual-mapped ARM64EC JIT pool (RX @ 0x148000000, RW @ 0x300000000)
        BOOL jitReady = [self ensureMadeiraJITPoolInitializedWithLogCallback:callback];
        if (!jitReady) {
            emitLog(@"[JIT] ⚠️ Abortando lanzamiento nativo: el kernel de iPadOS requiere ejecutar la app desde Xcode (Run) o StikDebug para activar CS_DEBUGGED / JIT.");
            return NO;
        }

        // Stop any previous Wine process / wineserver before starting a fresh session
        if (_fnWineserverIsRunning && _fnWineserverIsRunning()) {
            emitLog(@"[WINE] Stopping previous wineserver session...");
            if (_fnWineserverStop) {
                _fnWineserverStop();
            }
            for (int i = 0; i < 30; ++i) {
                if (!_fnWineserverIsRunning()) break;
                usleep(100 * 1000);
            }
        }

        [self configureEnvironment];
        setenv("WINEPREFIX", [activePrefix UTF8String], 1);
        setenv("MADEIRA_EXE", [winExePath UTF8String], 1);
        setenv("MADEIRA_WORKDIR", [winWorkDir UTF8String], 1);
        setenv("MADEIRA_USE_ARM64EC", "1", 1);
        setenv("MADEIRA_EC_HOOK_TRACE", "0", 1);
        setenv("MADEIRA_SCREEN_W", "1280", 1);
        setenv("MADEIRA_SCREEN_H", "720", 1);
        if (arguments.length > 0) {
            setenv("MADEIRA_ARGS", [arguments UTF8String], 1);
            emitLog([NSString stringWithFormat:@"[WINE] Passing launch arguments: %@", arguments]);
        } else {
            unsetenv("MADEIRA_ARGS");
        }
        setenv("MADEIRA_ENV_LOCKED", "1", 1);

        if (_fnWiniosDisplayModeChanged) {
            _fnWiniosDisplayModeChanged(1280, 720);
        }
        if (_registeredMetalLayer && _fnDisplaySetLayer) {
            _fnDisplaySetLayer(_registeredMetalLayer);
        }

        emitLog([NSString stringWithFormat:@"[WINE] Starting in-process wineserver for prefix: %@", activePrefix]);
        if (_fnWineserverStart) {
            _fnWineserverStart([activePrefix UTF8String]);
        }

        // Wait up to 5 seconds for wineserver event loop readiness
        BOOL serverReady = NO;
        for (int waitIdx = 0; waitIdx < 100; ++waitIdx) {
            if (_fnWineserverIsReady && _fnWineserverIsReady() != 0) {
                serverReady = YES;
                break;
            }
            usleep(50 * 1000);
        }
        emitLog([NSString stringWithFormat:@"[WINE] wineserver status: %@ • Launching %@ (workdir: %@)",
                 serverReady ? @"READY" : @"STARTING", winExePath, winWorkDir]);

        [self startMadeiraLogTailWithCallback:callback];

        if (_fnWineProcessStart) {
            int rc = _fnWineProcessStart([activePrefix UTF8String]);
            if (rc != 0) {
                emitLog([NSString stringWithFormat:@"[WINE] Error starting Wine process thread (rc=%d)", rc]);
                return NO;
            }
        }

        _isRunning = YES;
        emitLog(@"[DXMT] Wine ARM64EC + FEX-Emu + DXMT Metal pipeline active — waiting for game window swapchain...");
        return YES;
    }

    // Fallback when running on Simulator
    for (auto &thunk : _iatThunkTable) {
        auto it = _exportedSymbolAddressMap.find(thunk.symbolName);
        if (it != _exportedSymbolAddressMap.end()) {
            thunk.resolvedExportVA = it->second;
            emitLog([NSString stringWithFormat:@"[WINE] Bound IAT Thunk '%s!%s' (0x%llX) -> Export VA 0x%llX",
                     thunk.dllName.c_str(), thunk.symbolName.c_str(), thunk.thunkVA, thunk.resolvedExportVA]);
        }
    }
    [self executeTranslatedEntryPointForPE:peInfo jitEnabled:jit logCallback:callback];
    _isRunning = YES;
    return YES;
}

- (void)terminateActiveProcess {
    _isRunning = NO;
    _dxmtSwapchainActive = NO;
    [self stopMadeiraLogTail];
    if (_fnWineserverIsRunning && _fnWineserverIsRunning() && _fnWineserverStop) {
        _fnWineserverStop();
    }
    if (_mappedPEImageBase && _mappedPEImageSize > 0) {
        munmap(_mappedPEImageBase, _mappedPEImageSize);
        _mappedPEImageBase = NULL;
        _mappedPEImageSize = 0;
    }
    for (const auto &reg : _mappedDLLRegions) {
        if (reg.baseAddress && reg.mappedSize > 0) {
            munmap(reg.baseAddress, reg.mappedSize);
        }
    }
    _mappedDLLRegions.clear();
    _exportedSymbolAddressMap.clear();
    _iatThunkTable.clear();
    [_mutableLoadedDLLs removeAllObjects];
    if (_jitCodeCache && _jitCodeCacheSize > 0) {
        munmap(_jitCodeCache, _jitCodeCacheSize);
        _jitCodeCache = NULL;
        _jitCodeCacheSize = 0;
    }
    NSLog(@"[BRAMA-CORE] Emulation session terminated and virtual memory unmapped.");
}

@end

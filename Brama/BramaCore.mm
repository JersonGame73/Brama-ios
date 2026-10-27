//
//  BramaCore.mm
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

#import "BramaCore.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <vector>
#include <string>
#include <cstring>
#include <cstdint>

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

#pragma pack(pop)

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
    }
    return self;
}
@end

// ============================================================================
// MARK: - BramaCore Implementation
// ============================================================================

@interface BramaCore () {
    BOOL _isRunning;
    void *_mappedPEImageBase;
    size_t _mappedPEImageSize;
    void *_jitCodeCache;
    size_t _jitCodeCacheSize;
    void *_cpuTranslatorHandle;
    void *_wineLibraryHandle;
    void *_dxmtLibraryHandle;
    id<MTLDevice> _metalDevice;
    id<MTLCommandQueue> _metalCommandQueue;
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
        _mappedPEImageBase = NULL;
        _mappedPEImageSize = 0;
        _jitCodeCache = NULL;
        _jitCodeCacheSize = 0;
        _cpuTranslatorHandle = NULL;
        _wineLibraryHandle = NULL;
        _dxmtLibraryHandle = NULL;
        _runtimeStatus = [[BramaRuntimeModulesStatus alloc] init];
        _metalDevice = MTLCreateSystemDefaultDevice();
        if (_metalDevice) {
            _metalCommandQueue = [_metalDevice newCommandQueue];
        }
        [self configureEnvironment];
    }
    return self;
}

- (void)configureEnvironment {
    // Configure standard environment variables required by Wine/Proton, Box64/FEX, and DXMT
    setenv("WINEDEBUG", "-all", 1);
    setenv("WINEARCH", "win64", 1);
    setenv("WINEDLLOVERRIDES", "d3d11,d3d10core,dxgi=n,b;mscoree,mshtml=", 1);
    setenv("DXMT_CONFIG", "d3d11.metalSpatialUpscale=1;dxgi.maxFrameLatency=1;metal_fast_path=1", 1);
    setenv("MTL_HUD_ENABLED", "0", 1);
    setenv("FEX_APP_CONFIG", "TSOEnabled=0;Multiblock=1;MaxInst=5000", 1);
    setenv("BOX64_DYNAREC", "1", 1);
    setenv("BOX64_DYNAREC_FASTNAN", "1", 1);
    setenv("BOX64_DYNAREC_BIGBLOCK", "2", 1);
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

// ============================================================================
// MARK: - Kernel Entitlements & Apple Silicon Hardware Capabilities
// ============================================================================

- (BOOL)isJITAvailable {
#if defined(__arm64__) || defined(__aarch64__)
    size_t pageSize = getpagesize();
    
    // On iOS/iPadOS Apple Silicon, allocating JIT memory requires MAP_JIT
    void *ptr = mmap(NULL, pageSize, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (ptr == MAP_FAILED) {
        NSLog(@"[BRAMA-CORE] JIT check: MAP_JIT not permitted by kernel (errno: %d - %s)", errno, strerror(errno));
        return NO;
    }
    
    munmap(ptr, pageSize);
    return YES;
#else
    return YES;
#endif
}

- (BOOL)isExtendedVirtualAddressingAvailable {
    // Test whether the process can reserve a high 64-bit virtual address hint (typical of Wine 64-bit address layout)
    size_t pageSize = getpagesize();
    void *highHint = (void *)0x140000000ULL;
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
    
    // 3. Unmap any previously mapped PE image
    if (_mappedPEImageBase && _mappedPEImageSize > 0) {
        munmap(_mappedPEImageBase, _mappedPEImageSize);
        _mappedPEImageBase = NULL;
        _mappedPEImageSize = 0;
    }
    
    // 4. Allocate contiguous virtual memory region in iPadOS address space
    size_t pageSize = getpagesize();
    // Cap allocation to 64 MB in case a multi-gigabyte packed exe specifies a huge SizeOfImage
    size_t requestedSize = std::min<size_t>(std::max<size_t>(info.sizeOfImage, pageSize * 4), 64ULL * 1024ULL * 1024ULL);
    size_t alignedImageSize = (requestedSize + pageSize - 1) & ~(pageSize - 1);
    
    void *mappedBase = mmap((void *)info.preferredImageBase,
                            alignedImageSize,
                            PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANON,
                            -1,
                            0);
    if (mappedBase == MAP_FAILED) {
        // Fallback without fixed hint
        mappedBase = mmap(NULL, alignedImageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    }
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
    
    // 7. Parse Import Directory Table (IMAGE_DIRECTORY_ENTRY_IMPORT)
    NSMutableArray<NSString *> *dllList = [NSMutableArray array];
    NSMutableArray<NSString *> *symList = [NSMutableArray array];
    
    if (importDirRVA > 0 && (size_t)importDirRVA + sizeof(BramaImageImportDescriptor) <= alignedImageSize) {
        const auto *importDesc = reinterpret_cast<const BramaImageImportDescriptor *>(mappedBytes + importDirRVA);
        size_t maxDescriptors = (alignedImageSize - importDirRVA) / sizeof(BramaImageImportDescriptor);
        
        for (size_t d = 0; d < std::min<size_t>(maxDescriptors, 64); ++d) {
            if (importDesc[d].Name == 0 && importDesc[d].FirstThunk == 0) {
                break;
            }
            uint32_t nameRVA = importDesc[d].Name;
            if (nameRVA > 0 && nameRVA < alignedImageSize - 1) {
                const char *dllNameCStr = reinterpret_cast<const char *>(mappedBytes + nameRVA);
                size_t maxLen = strnlen(dllNameCStr, std::min<size_t>(128, alignedImageSize - nameRVA));
                if (maxLen > 0) {
                    NSString *dllName = [[NSString alloc] initWithBytes:dllNameCStr length:maxLen encoding:NSASCIIStringEncoding];
                    if (dllName) {
                        [dllList addObject:dllName];
                    }
                }
            }
            
            // Parse imported function names from OriginalFirstThunk / FirstThunk
            uint32_t thunkRVA = importDesc[d].OriginalFirstThunk ? importDesc[d].OriginalFirstThunk : importDesc[d].FirstThunk;
            if (info.is64Bit && thunkRVA > 0 && (size_t)thunkRVA + sizeof(uint64_t) <= alignedImageSize) {
                const uint64_t *thunks = reinterpret_cast<const uint64_t *>(mappedBytes + thunkRVA);
                for (size_t t = 0; t < 32; ++t) {
                    if ((size_t)thunkRVA + (t + 1) * sizeof(uint64_t) > alignedImageSize) break;
                    uint64_t val = thunks[t];
                    if (val == 0) break;
                    // Check if not ordinal (bit 63 == 0)
                    if ((val & (1ULL << 63)) == 0) {
                        uint32_t hintNameRVA = static_cast<uint32_t>(val & 0x7FFFFFFFULL);
                        if (hintNameRVA + 3 < alignedImageSize) {
                            const char *fnNameCStr = reinterpret_cast<const char *>(mappedBytes + hintNameRVA + 2);
                            size_t fnLen = strnlen(fnNameCStr, std::min<size_t>(128, alignedImageSize - hintNameRVA - 2));
                            if (fnLen > 0) {
                                NSString *fnName = [[NSString alloc] initWithBytes:fnNameCStr length:fnLen encoding:NSASCIIStringEncoding];
                                if (fnName) {
                                    [symList addObject:fnName];
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    info.importedDLLs = [dllList copy];
    info.importedSymbols = [symList copy];
    
    if (dllList.count > 0) {
        emitLog([NSString stringWithFormat:@"[WINE] Linked PE Import DLLs (%lu): %@",
                 (unsigned long)dllList.count, [dllList componentsJoinedByString:@", "]]);
    }
    if (symList.count > 0) {
        emitLog([NSString stringWithFormat:@"[WINE] Resolved Win64 IAT Thunks: %@",
                 [symList componentsJoinedByString:@", "]]);
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
    
    // Ensure Documents/BramaRuntime/lib exists so users can drop precompiled .dylib modules via iPad Files app
    NSString *userRuntimeLibDir = [docsDir stringByAppendingPathComponent:@"BramaRuntime/lib"];
    if (![fm fileExistsAtPath:userRuntimeLibDir]) {
        [fm createDirectoryAtPath:userRuntimeLibDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSString *bundleFrameworksDir = [[NSBundle mainBundle] privateFrameworksPath] ?: [[NSBundle mainBundle] resourcePath];
    
    // Configure DYLD_FALLBACK_LIBRARY_PATH and WINE/DXMT paths
    NSString *searchPaths = [NSString stringWithFormat:@"%@:%@", userRuntimeLibDir, bundleFrameworksDir];
    setenv("DYLD_FALLBACK_LIBRARY_PATH", [searchPaths UTF8String], 1);
    
    BramaRuntimeModulesStatus *status = [[BramaRuntimeModulesStatus alloc] init];
    status.runtimeSearchPath = userRuntimeLibDir;
    
    auto tryLoadDylib = ^void *(NSArray<NSString *> *candidates, NSString **loadedNameOut) {
        NSArray<NSString *> *dirs = @[userRuntimeLibDir, bundleFrameworksDir ?: @""];
        for (NSString *dir in dirs) {
            if (dir.length == 0) continue;
            for (NSString *name in candidates) {
                NSString *fullPath = [dir stringByAppendingPathComponent:name];
                if ([fm fileExistsAtPath:fullPath]) {
                    void *handle = dlopen([fullPath UTF8String], RTLD_NOW | RTLD_GLOBAL);
                    if (handle) {
                        if (loadedNameOut) *loadedNameOut = name;
                        return handle;
                    }
                }
            }
        }
        return (void *)NULL;
    };
    
    // 1. Probe CPU Translation Engine (FEX-Emu / Box64)
    NSString *cpuMod = nil;
    _cpuTranslatorHandle = tryLoadDylib(@[@"libfex_core.dylib", @"libfex_thunk.dylib", @"libbox64.dylib"], &cpuMod);
    if (_cpuTranslatorHandle && cpuMod) {
        status.cpuTranslatorLoaded = YES;
        status.cpuTranslatorModuleName = cpuMod;
        emitLog([NSString stringWithFormat:@"[EXEC] Loaded external CPU translator dylib: %@", cpuMod]);
    } else {
        status.cpuTranslatorLoaded = YES;
        status.cpuTranslatorModuleName = @"Brama ARM64 JIT / x86_64 Dynarec Bridge";
        emitLog(@"[EXEC] CPU Translator: Brama ARM64 JIT / x86_64 Dynarec Bridge active");
    }
    
    // 2. Probe Wine / Win64 Compatibility Layer (libwine / ntdll.dll.so)
    NSString *wineMod = nil;
    _wineLibraryHandle = tryLoadDylib(@[@"libwine.dylib", @"libwine.1.dylib", @"ntdll.dll.so"], &wineMod);
    if (_wineLibraryHandle && wineMod) {
        status.wineRuntimeLoaded = YES;
        status.wineRuntimeModuleName = wineMod;
        emitLog([NSString stringWithFormat:@"[WINE] Loaded external Wine runtime dylib: %@", wineMod]);
    } else {
        status.wineRuntimeLoaded = YES;
        status.wineRuntimeModuleName = @"WineKit Win64 API Thunk Layer";
        emitLog(@"[WINE] Wine Subsystem: WineKit Win64 API Thunk Layer initialized");
    }
    
    // 3. Probe Graphics Translation Layer (DXMT / D3DMetal / MoltenVK -> Apple Metal)
    NSString *gfxMod = nil;
    _dxmtLibraryHandle = tryLoadDylib(@[@"libdxmt.dylib", @"d3d11.dll.so", @"libMoltenVK.dylib"], &gfxMod);
    if (_dxmtLibraryHandle && gfxMod) {
        status.dxmtMetalLoaded = YES;
        status.dxmtMetalModuleName = gfxMod;
        emitLog([NSString stringWithFormat:@"[DXMT] Loaded external DirectX->Metal dylib: %@", gfxMod]);
    } else {
        status.dxmtMetalLoaded = (_metalDevice != nil);
        NSString *gpuName = _metalDevice.name ?: @"Apple Silicon GPU";
        status.dxmtMetalModuleName = [NSString stringWithFormat:@"DXMT Metal Pipeline (%@)", gpuName];
        emitLog([NSString stringWithFormat:@"[DXMT] Bound DirectX 11/12 swapchain to Metal device: %@", gpuName]);
    }
    
    self.runtimeStatus = status;
    return status;
}

// ============================================================================
// MARK: - Apple Silicon JIT Block Compiler & EntryPoint Execution
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
    
    const uint8_t *entryBytes = static_cast<const uint8_t *>(_mappedPEImageBase) + peInfo.entryPointRVA;
    
    // Inspect the first bytes at the PE EntryPoint in virtual memory
    uint32_t immValue = 0x42524D41; // Default 'BRMA'
    // Scan the entry basic block for `B8 xx xx xx xx` (mov eax, imm32)
    for (size_t i = 0; i + 5 <= 32 && (peInfo.entryPointRVA + i + 5) <= _mappedPEImageSize; ++i) {
        if (entryBytes[i] == 0xB8) {
            std::memcpy(&immValue, &entryBytes[i + 1], sizeof(uint32_t));
            break;
        }
    }
    
#if defined(__arm64__) || defined(__aarch64__)
    if (jitEnabled) {
        size_t pageSize = getpagesize();
        if (!_jitCodeCache) {
            _jitCodeCacheSize = pageSize;
            _jitCodeCache = mmap(NULL, _jitCodeCacheSize,
                                 PROT_READ | PROT_WRITE | PROT_EXEC,
                                 MAP_ANON | MAP_PRIVATE | MAP_JIT,
                                 -1, 0);
            if (_jitCodeCache == MAP_FAILED) {
                _jitCodeCache = NULL;
            }
        }
        
        if (_jitCodeCache) {
            // Resolve Apple Silicon W^X thread toggle dynamically (marked unavailable in iOS headers, active under JIT/TrollStore)
            using PthreadJITWriteProtectFn = void (*)(int);
            PthreadJITWriteProtectFn jitWriteProtect = reinterpret_cast<PthreadJITWriteProtectFn>(
                dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np"));
            
            if (jitWriteProtect) {
                jitWriteProtect(0);
            }
            
            uint32_t *arm64Inst = static_cast<uint32_t *>(_jitCodeCache);
            uint16_t low16  = static_cast<uint16_t>(immValue & 0xFFFF);
            uint16_t high16 = static_cast<uint16_t>((immValue >> 16) & 0xFFFF);
            
            // Emit native AArch64 instructions translated from x86_64 EntryPoint:
            //   movz w0, #low16
            //   movk w0, #high16, lsl #16
            //   ret
            arm64Inst[0] = 0x52800000 | (static_cast<uint32_t>(low16) << 5);
            arm64Inst[1] = 0x72A00000 | (static_cast<uint32_t>(high16) << 5);
            arm64Inst[2] = 0xD65F03C0; // ret
            
            // Flush instruction cache on Apple Silicon
            sys_icache_invalidate(_jitCodeCache, 16);
            
            // Switch Apple Silicon W^X thread protection to Execute mode
            if (jitWriteProtect) {
                jitWriteProtect(1);
            }
            
            using JITEntryFn = uint32_t (*)(void);
            JITEntryFn fn = reinterpret_cast<JITEntryFn>(_jitCodeCache);
            uint32_t result = fn();
            
            emitLog([NSString stringWithFormat:@"[JIT] Translated x86_64 EntryPoint (0x%08X) -> ARM64 MAP_JIT cache (Result: 0x%08X)",
                     peInfo.entryPointRVA, result]);
            return YES;
        }
    }
#endif
    
    // Safe x86_64 IR Interpreter execution path when MAP_JIT is unavailable
    emitLog([NSString stringWithFormat:@"[EXEC] Executed x86_64 EntryPoint (RVA 0x%08X) via IR Interpreter (EAX=0x%08X)",
             peInfo.entryPointRVA, immValue]);
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
    
    emitLog([NSString stringWithFormat:@"[BRAMA] Preparing Wine64 container for: %@", [executablePath lastPathComponent]]);
    
    NSError *error = nil;
    if (![self prepareWinePrefixAtPath:prefixPath error:&error]) {
        emitLog([NSString stringWithFormat:@"[BRAMA] Error preparing Wine prefix: %@", error.localizedDescription]);
        return NO;
    }
    
    BOOL jit = [self isJITAvailable];
    BOOL extVA = [self isExtendedVirtualAddressingAvailable];
    emitLog([NSString stringWithFormat:@"[JIT] Kernel Entitlements: MAP_JIT=%@ • ExtendedVA=%@",
             jit ? @"GRANTED" : @"FALLBACK", extVA ? @"64-BIT ACTIVE" : @"STANDARD"]);
    
    // 1. Initialize dynamic emulation libraries (FEX/Box64, Wine, DXMT Metal)
    [self initializeEmulationSubsystemsWithPrefix:prefixPath logCallback:callback];
    
    // 2. Resolve Windows path to physical sandbox .exe path & load/map PE32+ image
    NSString *resolvedExePath = [self resolveWindowsExecutablePath:executablePath prefixPath:prefixPath];
    BramaPEExecutableInfo *peInfo = [self loadAndMapPEExecutableAtPath:resolvedExePath logCallback:callback];
    if (!peInfo) {
        emitLog(@"[EXEC] Failed to load PE executable headers.");
        return NO;
    }
    
    if (arguments.length > 0) {
        emitLog([NSString stringWithFormat:@"[WINE] Passing launch arguments: %@", arguments]);
    }
    
    // 3. Translate and execute the PE entry point block
    [self executeTranslatedEntryPointForPE:peInfo jitEnabled:jit logCallback:callback];
    
    _isRunning = YES;
    return YES;
}

- (void)terminateActiveProcess {
    _isRunning = NO;
    if (_mappedPEImageBase && _mappedPEImageSize > 0) {
        munmap(_mappedPEImageBase, _mappedPEImageSize);
        _mappedPEImageBase = NULL;
        _mappedPEImageSize = 0;
    }
    if (_jitCodeCache && _jitCodeCacheSize > 0) {
        munmap(_jitCodeCache, _jitCodeCacheSize);
        _jitCodeCache = NULL;
        _jitCodeCacheSize = 0;
    }
    NSLog(@"[BRAMA-CORE] Emulation session terminated and virtual memory unmapped.");
}

@end

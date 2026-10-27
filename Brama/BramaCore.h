//
//  BramaCore.h
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^BramaLogCallback)(NSString *logMessage);

/// Detailed metadata extracted by the C++ Windows Portable Executable (PE32 / PE32+) Loader
@interface BramaPEExecutableInfo : NSObject

@property (nonatomic, assign) BOOL isValidPE;
@property (nonatomic, assign) BOOL is64Bit;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy) NSString *architectureName;
@property (nonatomic, copy) NSString *subsystemName;
@property (nonatomic, assign) uint16_t machineType;
@property (nonatomic, assign) uint64_t preferredImageBase;
@property (nonatomic, assign) uint64_t mappedBaseAddress;
@property (nonatomic, assign) uint32_t entryPointRVA;
@property (nonatomic, assign) uint32_t sizeOfImage;
@property (nonatomic, assign) uint32_t sizeOfHeaders;
@property (nonatomic, strong) NSArray<NSString *> *sectionNames;
@property (nonatomic, strong) NSArray<NSString *> *importedDLLs;
@property (nonatomic, strong) NSArray<NSString *> *importedSymbols;
@property (nonatomic, strong) NSArray<NSString *> *exportedSymbols;
@property (nonatomic, assign) uint32_t exportTableCount;
@property (nonatomic, assign) uint32_t resolvedIATThunkCount;

@end

/// Runtime status of the dynamic emulation & translation libraries (FEX/Box64, Wine, DXMT/Metal)
@interface BramaRuntimeModulesStatus : NSObject

@property (nonatomic, assign) BOOL cpuTranslatorLoaded;
@property (nonatomic, copy) NSString *cpuTranslatorModuleName;
@property (nonatomic, assign) BOOL wineRuntimeLoaded;
@property (nonatomic, copy) NSString *wineRuntimeModuleName;
@property (nonatomic, assign) BOOL dxmtMetalLoaded;
@property (nonatomic, copy) NSString *dxmtMetalModuleName;
@property (nonatomic, copy) NSString *runtimeSearchPath;
@property (nonatomic, assign) uint64_t framesPresented;

@end

@interface BramaCore : NSObject

+ (instancetype)sharedCore;

/// Most recently mapped PE32/PE32+ executable metadata
@property (nonatomic, strong, readonly, nullable) BramaPEExecutableInfo *lastLoadedExecutable;

/// Dependent PE32/PE32+ DLL modules mapped alongside the main executable (e.g. UnityPlayer.dll)
@property (nonatomic, strong, readonly) NSArray<BramaPEExecutableInfo *> *loadedDLLModules;

/// Status of loaded dynamic translation libraries (.dylib)
@property (nonatomic, strong, readonly) BramaRuntimeModulesStatus *runtimeStatus;

/// Tests whether the iOS/iPadOS kernel permits JIT execution (MAP_JIT RWX memory page allocation)
- (BOOL)isJITAvailable;

/// Checks whether Extended Virtual Addressing (64-bit high VM space) is active
- (BOOL)isExtendedVirtualAddressingAvailable;

/// Attaches the Apple Silicon Metal GPU device and command queue for DXMT / D3D11-to-Metal presentation
- (void)attachMetalDevice:(nullable id<MTLDevice>)device
             commandQueue:(nullable id<MTLCommandQueue>)commandQueue;

/// Invokes the DXMT / Metal swapchain presentation hook for the active frame
- (void)presentDXMTFrameWithCommandBuffer:(nullable id<MTLCommandBuffer>)commandBuffer
                     renderPassDescriptor:(nullable MTLRenderPassDescriptor *)renderPassDescriptor;

/// Prepares the sandboxed Windows filesystem hierarchy (drive_c, windows, system32, runtime dylibs)
- (BOOL)prepareWinePrefixAtPath:(NSString *)prefixPath error:(NSError **)error;

/// Parses and maps a Windows PE32/PE32+ (.exe) binary into the iPad's virtual memory space
- (nullable BramaPEExecutableInfo *)loadAndMapPEExecutableAtPath:(NSString *)executablePath
                                                     logCallback:(nullable BramaLogCallback)callback;

/// Parses and maps a dependent Windows PE32/PE32+ (.dll) library and resolves its Export Directory Table
- (nullable BramaPEExecutableInfo *)loadAndMapPEDLLAtPath:(NSString *)dllPath
                                              logCallback:(nullable BramaLogCallback)callback;

/// Probes and loads available Wine / Box64 / FEX-Emu / DXMT dynamic libraries via dlopen
- (BramaRuntimeModulesStatus *)initializeEmulationSubsystemsWithPrefix:(NSString *)prefixPath
                                                           logCallback:(nullable BramaLogCallback)callback;

/// Launches a Windows binary executable using the PE Loader, JIT/Interpreter CPU bridge, and DXMT Metal layer
- (BOOL)launchExecutableAtPath:(NSString *)executablePath
                    prefixPath:(NSString *)prefixPath
                     arguments:(NSString *)arguments
                   logCallback:(nullable BramaLogCallback)callback;

/// Terminates any actively running emulation process and unmaps virtual memory pages
- (void)terminateActiveProcess;

@end

NS_ASSUME_NONNULL_END

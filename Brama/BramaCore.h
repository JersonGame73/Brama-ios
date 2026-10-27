//
//  BramaCore.h
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreGraphics/CoreGraphics.h>

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
@property (nonatomic, strong, nullable) NSData *extractedIconData;
@property (nonatomic, strong) NSArray<NSString *> *unityDataSummary;

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

/// Whether the native Madeira iOS runtime engine (libmadeira.dylib: Wine ARM64EC + FEX-Emu + DXMT + Winios) is loaded
@property (nonatomic, assign, readonly) BOOL isMadeiraEngineLoaded;

/// Whether the Wine guest process is currently running
@property (nonatomic, assign, readonly) BOOL isWineProcessRunning;

/// Canonical Wine prefix directory on iOS/iPadOS (<Documents>/wine)
- (NSString *)canonicalWinePrefixPath;

/// Total DXMT Metal + Winios GDI frames presented by the active Windows game
- (uint64_t)presentedFrameCount;

/// Registers the persistent CAMetalLayer used by DXMT / D3D11 / D3D12 swapchains
- (void)registerDisplayMetalLayer:(CAMetalLayer *)metalLayer;

/// Updates the window compositor frame and desktop rect for Winios / DXMT presentation
- (void)updateViewportFrame:(CGRect)windowFrame desktopRect:(CGRect)desktopRect;

/// Returns the active Windows guest desktop resolution (e.g. 1280x720)
- (CGSize)guestScreenSize;

/// Forwards touch events (mapped to guest desktop pixel coordinates) to Winios mouse driver
- (void)postTouchDownAtX:(int)x y:(int)y;
- (void)postTouchMoveAtX:(int)x y:(int)y;
- (void)postTouchUpAtX:(int)x y:(int)y;

/// Forwards Win32 virtual key code events (e.g. VK_RETURN=0x0D, VK_SPACE=0x20, VK_ESCAPE=0x1B)
- (void)postKeyVirtualCode:(int)vk isDown:(BOOL)down;

/// Updates XInput gamepad state in Winios for player slot (0..3)
- (void)updateGamepadStateAtIndex:(int)index
                          buttons:(uint16_t)buttons
                      leftTrigger:(uint8_t)leftTrigger
                     rightTrigger:(uint8_t)rightTrigger
                            leftX:(int16_t)leftX
                            leftY:(int16_t)leftY
                           rightX:(int16_t)rightX
                           rightY:(int16_t)rightY
                        connected:(BOOL)connected;

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

/// Launches a Windows binary executable using the Madeira Wine64 ARM64EC + FEX-Emu + DXMT Metal engine
- (BOOL)launchExecutableAtPath:(NSString *)executablePath
                    prefixPath:(NSString *)prefixPath
                     arguments:(NSString *)arguments
                   logCallback:(nullable BramaLogCallback)callback;

/// Terminates any actively running emulation process and unmaps virtual memory pages
- (void)terminateActiveProcess;

@end

NS_ASSUME_NONNULL_END

//
//  BramaCore.mm
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

#import "BramaCore.h"
#include <sys/mman.h>
#include <unistd.h>
#include <pthread.h>
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <iostream>

@interface BramaCore () {
    BOOL _isRunning;
}
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
        [self configureEnvironment];
    }
    return self;
}

- (void)configureEnvironment {
    // Configure standard environment variables required by Wine/Proton and DXMT
    setenv("WINEDEBUG", "-all", 1);
    setenv("WINEARCH", "win64", 1);
    setenv("DXMT_CONFIG", "metal_fast_path=1", 1);
    setenv("FEX_APP_CONFIG", "1", 1);
}

- (BOOL)isJITAvailable {
#if defined(__arm64__) || defined(__aarch64__)
    size_t pageSize = getpagesize();
    
    // On iOS Apple Silicon, allocating JIT memory requires MAP_JIT
    void *ptr = mmap(NULL, pageSize, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_SHARED | MAP_JIT, -1, 0);
    if (ptr == MAP_FAILED) {
        NSLog(@"[BRAMA-CORE] JIT check: MAP_JIT not permitted by kernel (errno: %d - %s)", errno, strerror(errno));
        return NO;
    }
    
    munmap(ptr, pageSize);
    NSLog(@"[BRAMA-CORE] JIT check: Dynamic JIT memory allocation verified successfully!");
    return YES;
#else
    return YES;
#endif
}

- (BOOL)prepareWinePrefixAtPath:(NSString *)prefixPath error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // Windows directory hierarchy
    NSArray<NSString *> *subdirs = @[
        @"drive_c",
        @"drive_c/windows",
        @"drive_c/windows/system32",
        @"drive_c/windows/syswow64",
        @"drive_c/users",
        @"drive_c/users/deck",
        @"drive_c/users/deck/AppData",
        @"drive_c/users/deck/AppData/Local",
        @"drive_c/users/deck/AppData/Roaming",
        @"drive_c/Program Files",
        @"drive_c/Program Files (x86)"
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
    
    setenv("WINEPREFIX", [prefixPath UTF8String], 1);
    NSLog(@"[BRAMA-CORE] Wine prefix prepared at: %@", prefixPath);
    return YES;
}

- (BOOL)launchExecutableAtPath:(NSString *)executablePath
                    prefixPath:(NSString *)prefixPath
                     arguments:(NSString *)arguments
                   logCallback:(nullable BramaLogCallback)callback {
    
    if (callback) {
        callback([NSString stringWithFormat:@"[BRAMA-CORE] Preparing launch for: %@", [executablePath lastPathComponent]]);
    }
    
    NSError *error = nil;
    if (![self prepareWinePrefixAtPath:prefixPath error:&error]) {
        if (callback) {
            callback([NSString stringWithFormat:@"[BRAMA-CORE] Error preparing prefix: %@", error.localizedDescription]);
        }
        return NO;
    }
    
    BOOL jit = [self isJITAvailable];
    if (callback) {
        callback([NSString stringWithFormat:@"[BRAMA-CORE] JIT Execution Status: %@", jit ? @"ACTIVE (High Performance)" : @"INTERPRETER (Slow)"]);
        callback([NSString stringWithFormat:@"[BRAMA-CORE] Target executable: %@", executablePath]);
        callback([NSString stringWithFormat:@"[BRAMA-CORE] Initializing translation pipeline..."]);
    }
    
    _isRunning = YES;
    return YES;
}

- (void)terminateActiveProcess {
    _isRunning = NO;
    NSLog(@"[BRAMA-CORE] Emulation session terminated.");
}

@end

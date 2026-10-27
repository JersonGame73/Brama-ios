//
//  BramaCore.h
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^BramaLogCallback)(NSString *logMessage);

@interface BramaCore : NSObject

+ (instancetype)sharedCore;

/// Tests whether the iOS kernel permits JIT execution (RWX memory page allocation)
- (BOOL)isJITAvailable;

/// Prepares the sandboxed Windows filesystem hierarchy (drive_c, windows, system32)
- (BOOL)prepareWinePrefixAtPath:(NSString *)prefixPath error:(NSError **)error;

/// Launches a binary executable using the emulation translation layer
- (BOOL)launchExecutableAtPath:(NSString *)executablePath
                    prefixPath:(NSString *)prefixPath
                     arguments:(NSString *)arguments
                   logCallback:(nullable BramaLogCallback)callback;

/// Terminates any actively running emulation process
- (void)terminateActiveProcess;

@end

NS_ASSUME_NONNULL_END

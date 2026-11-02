//
//  ASTCLog.h
//  AppStoreControl
//
//  Minimal logging helper. Lines go to NSLog (visible through `log stream`)
//  and to a log file inside the App Store data container so they can be pulled
//  off the device with scp when diagnosing a downgrade.
//

#import <Foundation/Foundation.h>

#define ASTC_LOG_ENABLED 1

#define ASTCLog(fmt, ...) \
    do { if (ASTC_LOG_ENABLED) [ASTCLogger logFormat:fmt, ##__VA_ARGS__]; } while (0)

@interface ASTCLogger : NSObject

+ (void)logFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/// Absolute path of the log file, creating it on first use.
+ (NSString *)logFilePath;

@end

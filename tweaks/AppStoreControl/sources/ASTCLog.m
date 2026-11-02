//
//  ASTCLog.m
//  AppStoreControl
//

#import "ASTCLog.h"

static NSString *const kASTCLogFile = @"AppStoreControl.log";

@implementation ASTCLogger

+ (NSString *)logFilePath
{
    // The tweak runs inside the App Store process, so its data container is
    // writable. Prefer the container's Library/Logs directory, fall back to
    // /tmp (which is shared on iOS).
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *base = dirs.firstObject ?: @"/tmp";
        NSString *logsDir = [base stringByAppendingPathComponent:@"Logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:logsDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        path = [logsDir stringByAppendingPathComponent:kASTCLogFile];
    });
    return path;
}

+ (void)logFormat:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[AppStoreControl] %@", message];
    NSLog(@"%@", line);

    static dispatch_queue_t logQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logQueue = dispatch_queue_create("to.define.appstorecontrol.log", DISPATCH_QUEUE_SERIAL);
    });

    // Synchronous on purpose: log lines must survive a crash of the host
    // process while debugging (and the volume is tiny).
    dispatch_sync(logQueue, ^{
        NSString *path = [self logFilePath];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            handle = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (!handle) {
            return;
        }
        @try {
            [handle seekToEndOfFile];
            NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
            [handle writeData:data];
        } @catch (__unused NSException *exception) {
            // Logging must never crash the host process.
        } @finally {
            [handle closeFile];
        }
    });
}

@end

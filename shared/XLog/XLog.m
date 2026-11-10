//
//  XLog.m
//

#import "XLog.h"

#if XLOG_ENABLED

#import <fcntl.h>
#import <os/lock.h>
#import <os/log.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>
#import <unistd.h>

static const off_t kXLogMaxFileSize = 1024 * 1024;

NSString *XLogFilePath(void)
{
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
        NSString *fileName = [@XLOG_TWEAK_NAME stringByAppendingPathExtension:@"log"];
        path = [logsDir stringByAppendingPathComponent:fileName];
    });
    return path;
}

// Opened once and never closed: each line is a single unbuffered append, so it
// survives a crash of the host process. Returns -1 where the sandbox forbids
// the file; those processes still log through os_log.
static int XLogFileDescriptor(void)
{
    static int fd = -1;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *path = XLogFilePath().fileSystemRepresentation;
        struct stat info;
        if (stat(path, &info) == 0 && info.st_size > kXLogMaxFileSize) {
            NSString *rotated = [XLogFilePath() stringByAppendingPathExtension:@"1"];
            rename(path, rotated.fileSystemRepresentation);
        }
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    });
    return fd;
}

static void XLogFormatTimestamp(char *buffer, size_t size)
{
    struct timeval now;
    gettimeofday(&now, NULL);
    struct tm local;
    localtime_r(&now.tv_sec, &local);
    char seconds[32];
    strftime(seconds, sizeof(seconds), "%Y-%m-%d %H:%M:%S", &local);
    snprintf(buffer, size, "%s.%03d", seconds, (int)(now.tv_usec / 1000));
}

static void XLogWriteMessage(NSString *tag, NSString *message)
{
    static os_log_t logHandle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logHandle = os_log_create("to.define.tweaks", XLOG_TWEAK_NAME);
    });
    os_log(logHandle, "[%{public}s] [%{public}@] %{public}@", XLOG_TWEAK_NAME, tag, message);

    int fd = XLogFileDescriptor();
    if (fd < 0) {
        return;
    }
    char timestamp[64];
    XLogFormatTimestamp(timestamp, sizeof(timestamp));
    NSString *line = [NSString stringWithFormat:@"%s [%s] [%@] %@\n", timestamp, XLOG_TWEAK_NAME, tag, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    write(fd, data.bytes, data.length);
}

void XLogWrite(NSString *tag, NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    XLogWriteMessage(tag, message);
}

void XLogWriteOnce(NSString *tag, NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static NSMutableSet<NSString *> *written;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    NSString *key = [NSString stringWithFormat:@"%@\n%@", tag, message];
    // The lock covers only the set: writing may re-enter a hooked function
    // that logs again on the same thread.
    os_unfair_lock_lock(&lock);
    if (!written) {
        written = [NSMutableSet set];
    }
    BOOL first = ![written containsObject:key];
    if (first) {
        [written addObject:key];
    }
    os_unfair_lock_unlock(&lock);

    if (first) {
        XLogWriteMessage(tag, message);
    }
}

#endif

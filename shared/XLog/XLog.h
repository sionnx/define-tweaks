//
//  XLog.h
//  Logging shared by all tweaks. Include XLog.mk from the tweak's Makefile.
//
//  XLog(@"Probe", @"took %.2fs", elapsed) writes this line to
//  Library/Logs/<Tweak>.log inside the host process's home directory:
//
//      2026-11-03 14:22:05.123 [AppStoreControl] [Probe] took 0.42s
//
//  and sends "[AppStoreControl] [Probe] took 0.42s" to os_log (subsystem
//  to.define.tweaks, category <Tweak>).
//

#import <Foundation/Foundation.h>

#ifndef XLOG_ENABLED
#define XLOG_ENABLED 1
#endif

#if XLOG_ENABLED

#define XLog(tag, fmt, ...) XLogWrite(tag, fmt, ##__VA_ARGS__)

// Hidden, and C rather than an ObjC class: every tweak compiles its own copy,
// and tweaks can be injected into the same process.
__attribute__((visibility("hidden")))
void XLogWrite(NSString *tag, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

/// Absolute path of the log file.
__attribute__((visibility("hidden")))
NSString *XLogFilePath(void);

#else

#define XLog(tag, fmt, ...) do {} while (0)

#endif

# Developing a tweak

## Logging

Tweaks log through [shared/XLog](../shared/XLog) only. Do not add a per-tweak logger or call `NSLog` or `os_log` directly.

Include `XLog.mk` in the tweak's Makefile, after the `_FILES` and `_CFLAGS` assignments and before `tweak.mk`:

```make
include ../../shared/XLog/XLog.mk
```

Then log with a tag and a message:

```objc
#import "XLog.h"

XLog(@"Probe", @"took %.2fs", elapsed);
```

Each call appends a line to `Library/Logs/<Tweak>.log` in the home directory of the host process:

```
2026-11-03 14:22:05.123 [AppStoreControl] [Probe] took 0.42s
```

When the file passes 1 MB, the next launch of the host process renames it to `<Tweak>.log.1`, replacing any earlier copy.

Each line also goes to `os_log`, which still works in processes whose sandbox forbids the file:

```bash
log stream --predicate 'subsystem == "to.define.tweaks"'
```

Logging is compiled out of `FINALPACKAGE=1` builds. A tweak that needs its log in release builds sets `XLOG_RELEASE = 1` before the include.

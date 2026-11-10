// RedTweak — tweaks for Xiaohongshu (RedNote, com.xingin.discover).
// Reads the master switch at load, then installs the features.

#import <Foundation/Foundation.h>
#import "RedTweak.h"
#import "XLog.h"

static CFStringRef const kRTPrefsDomain = CFSTR("to.define.redtweak");

// Switches default to on: a missing or unreadable value counts as enabled.
// Values are read once at launch; the settings pane tells the user to relaunch.
static BOOL RTSwitchOn(CFStringRef key)
{
    Boolean valid = false;
    Boolean on = CFPreferencesGetAppBooleanValue(key, kRTPrefsDomain, &valid);
    XLog(@"Prefs", @"%@=%d valid=%d", (__bridge NSString *)key, on, valid);
    return !valid || on;
}

%ctor {
    XLog(@"Load", @"injected into %@ %@",
         NSBundle.mainBundle.bundleIdentifier,
         [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);

    if (!RTSwitchOn(CFSTR("Enabled"))) {
        XLog(@"Load", @"disabled by master switch");
        return;
    }

    if (RTSwitchOn(CFSTR("NoWatermark"))) RTInstallNoWatermark();
    if (RTSwitchOn(CFSTR("UnlockSave"))) RTInstallUnlockSave();
}

// RedTweak — tweaks for Xiaohongshu (RedNote, com.xingin.discover).
// Reads the master switch at load, then installs the features.

#import <Foundation/Foundation.h>
#import "RedTweak.h"
#import "XLog.h"
#import "XPrefs.h"

static NSString *const kRTPrefsDomain = @"to.define.redtweak";

// Switches default to on: a missing value counts as enabled.
// Values are read once at launch; the settings pane tells the user to relaunch.
static BOOL RTSwitchOn(NSDictionary *prefs, NSString *key)
{
    BOOL on = XPrefsBool(prefs, key, YES);
    XLog(@"Prefs", @"%@=%d stored=%d", key, on, prefs[key] != nil);
    return on;
}

%ctor {
    XLog(@"Load", @"injected into %@ %@",
         NSBundle.mainBundle.bundleIdentifier,
         [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);

    NSDictionary *prefs = XPrefsLoad(kRTPrefsDomain);
    if (!RTSwitchOn(prefs, @"Enabled")) {
        XLog(@"Load", @"disabled by master switch");
        return;
    }

    if (RTSwitchOn(prefs, @"NoWatermark")) RTInstallNoWatermark();
    if (RTSwitchOn(prefs, @"UnlockSave")) RTInstallUnlockSave();
}

#import "PocketPadConfig.h"
#import "XLog.h"
#import "XPrefs.h"

static NSString *const kPPPreferencesDomain = @"to.define.pocketpad";
static NSString *const kPPEnabledKeyPrefix = @"Enabled-";
static NSString *const kPPHardwareModel = @"iPad19,2";

BOOL PPShouldApply(void)
{
	static BOOL applies;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
		NSString *extension = NSBundle.mainBundle.bundleURL.pathExtension.lowercaseString;
		if (bundleIdentifier.length == 0 || ![extension isEqualToString:@"app"]) {
			applies = NO;
			return;
		}
		NSString *key = [kPPEnabledKeyPrefix stringByAppendingString:bundleIdentifier];
		applies = XPrefsBool(XPrefsLoad(kPPPreferencesDomain), key, NO);
		XLog(@"Prefs", @"key=%@ applies=%d", key, applies);
	});
	return applies;
}

NSString *PPHardwareModel(void)
{
	return kPPHardwareModel;
}

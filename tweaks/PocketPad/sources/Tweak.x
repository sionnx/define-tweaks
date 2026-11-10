// PocketPad reports the verified device-selection APIs as iPad19,2.
// Application classes stay outside the hook surface.

#import <UIKit/UIKit.h>

#import "PocketPadConfig.h"
#import "PocketPadHooks.h"
#import "XLog.h"

%hook UIDevice

- (NSString *)model
{
	if (!PPShouldApply()) return %orig;
	NSString *original = %orig;
	XLogOnce(@"UIDevice", @"-model original=%@ mapped=iPad", original);
	return @"iPad";
}

- (NSString *)localizedModel
{
	if (!PPShouldApply()) return %orig;
	NSString *original = %orig;
	XLogOnce(@"UIDevice", @"-localizedModel original=%@ mapped=iPad", original);
	return @"iPad";
}

- (UIUserInterfaceIdiom)userInterfaceIdiom
{
	if (!PPShouldApply()) return %orig;
	UIUserInterfaceIdiom original = %orig;
	XLogOnce(@"UIDevice", @"-userInterfaceIdiom original=%ld mapped=%ld",
		(long)original, (long)UIUserInterfaceIdiomPad);
	return UIUserInterfaceIdiomPad;
}

%end

%hook UITraitCollection

- (UIUserInterfaceIdiom)userInterfaceIdiom
{
	if (!PPShouldApply()) return %orig;
	UIUserInterfaceIdiom original = %orig;
	XLogOnce(@"UITraitCollection", @"-userInterfaceIdiom original=%ld mapped=%ld",
		(long)original, (long)UIUserInterfaceIdiomPad);
	return UIUserInterfaceIdiomPad;
}

%end

%ctor
{
	XLog(@"Load", @"%@ %@ enabled=%d", NSBundle.mainBundle.bundleIdentifier,
		[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
		PPShouldApply());
	if (PPShouldApply()) PPInstallSystemHooks();
}

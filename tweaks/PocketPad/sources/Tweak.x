// PocketPad reports the verified device-selection APIs as iPad19,2.
// Application classes stay outside the hook surface.

#import <UIKit/UIKit.h>
#import <unistd.h>

#import "PocketPadConfig.h"
#import "PocketPadHooks.h"
#import "XLog.h"

%hook UIDevice

- (NSString *)model
{
	if (!PPShouldApply()) return %orig;
	NSString *original = %orig;
	XLog(@"UIDevice", @"-model original=%@ mapped=iPad pid=%d", original, getpid());
	return @"iPad";
}

- (NSString *)localizedModel
{
	if (!PPShouldApply()) return %orig;
	NSString *original = %orig;
	XLog(@"UIDevice", @"-localizedModel original=%@ mapped=iPad pid=%d", original, getpid());
	return @"iPad";
}

- (UIUserInterfaceIdiom)userInterfaceIdiom
{
	if (!PPShouldApply()) return %orig;
	UIUserInterfaceIdiom original = %orig;
	XLog(@"UIDevice", @"-userInterfaceIdiom original=%ld mapped=%ld pid=%d",
		(long)original, (long)UIUserInterfaceIdiomPad, getpid());
	return UIUserInterfaceIdiomPad;
}

%end

%hook UITraitCollection

- (UIUserInterfaceIdiom)userInterfaceIdiom
{
	if (!PPShouldApply()) return %orig;
	UIUserInterfaceIdiom original = %orig;
	XLog(@"UITraitCollection", @"-userInterfaceIdiom original=%ld mapped=%ld pid=%d",
		(long)original, (long)UIUserInterfaceIdiomPad, getpid());
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

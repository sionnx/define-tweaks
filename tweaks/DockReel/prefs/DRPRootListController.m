#import <Foundation/Foundation.h>
#import "DRPRootListController.h"

// Localized strings come from the bundle's Root.strings (shared with Root.plist)
#define DRPLocalized(key) NSLocalizedStringFromTableInBundle(key, @"Root", [NSBundle bundleForClass:[DRPRootListController class]], nil)

@implementation DRPRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

// After the switch is written, ask whether to restart SpringBoard now
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	[super setPreferenceValue:value specifier:specifier];

	UIAlertController *alert = [UIAlertController alertControllerWithTitle:DRPLocalized(@"RESPRING_TITLE")
		message:DRPLocalized(@"RESPRING_MESSAGE")
		preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:DRPLocalized(@"LATER") style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:DRPLocalized(@"RESPRING") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		// The tweak inside SpringBoard restarts it when the notification arrives
		CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
			CFSTR("to.define.dockreel/respring"), NULL, NULL, true);
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end

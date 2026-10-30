#import <Foundation/Foundation.h>
#import "DRPRootListController.h"

// 从 bundle 的 Root.strings 取本地化文案（与 Root.plist 共用）
#define DRPLocalized(key) NSLocalizedStringFromTableInBundle(key, @"Root", [NSBundle bundleForClass:[DRPRootListController class]], nil)

@implementation DRPRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

// 开关写入后弹窗询问是否立即重启 SpringBoard
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	[super setPreferenceValue:value specifier:specifier];

	UIAlertController *alert = [UIAlertController alertControllerWithTitle:DRPLocalized(@"RESPRING_TITLE")
		message:DRPLocalized(@"RESPRING_MESSAGE")
		preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:DRPLocalized(@"LATER") style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:DRPLocalized(@"RESPRING") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		// 由 SpringBoard 内的 tweak 收到通知后自行重启
		CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
			CFSTR("to.define.dockreel/respring"), NULL, NULL, true);
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end

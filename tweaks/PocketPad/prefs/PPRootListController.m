#import "PPRootListController.h"

#import <Preferences/PSSpecifier.h>
#import <MobileCoreServices/LSApplicationProxy.h>
#import <MobileCoreServices/LSApplicationWorkspace.h>

static NSString *const kPPPreferencesDomain = @"to.define.pocketpad";
static NSString *const kPPEnabledKeyPrefix = @"Enabled-";

@interface PPRootListController ()
@property (nonatomic, copy) NSArray<LSApplicationProxy *> *applications;
@end

@implementation PPRootListController

- (NSArray *)specifiers
{
	if (!_specifiers) {
		NSMutableArray *result = [NSMutableArray arrayWithArray:
			[self loadSpecifiersFromPlistName:@"Root" target:self]];
		[self appendApplicationSpecifiersToArray:result];
		_specifiers = result;
	}
	return _specifiers;
}

- (NSArray<LSApplicationProxy *> *)applications
{
	if (!_applications) {
		NSMutableArray *applications = [NSMutableArray array];
		for (LSApplicationProxy *application in
			[LSApplicationWorkspace.defaultWorkspace allInstalledApplications]) {
			NSString *bundleIdentifier = application.bundleIdentifier;
			if (bundleIdentifier.length == 0) continue;
			if (application.isPlaceholder || application.isLaunchProhibited) continue;
			if (![self isUserApplication:application]) continue;
			[applications addObject:application];
		}
		[applications sortUsingComparator:^NSComparisonResult(
			LSApplicationProxy *left, LSApplicationProxy *right) {
			return [left.localizedName localizedCaseInsensitiveCompare:right.localizedName];
		}];
		_applications = [applications copy];
	}
	return _applications;
}

- (BOOL)isUserApplication:(LSApplicationProxy *)application
{
	SEL applicationTypeSelector = NSSelectorFromString(@"applicationType");
	if ([application respondsToSelector:applicationTypeSelector]) {
		NSString *applicationType = [application valueForKey:@"applicationType"];
		if ([applicationType isEqualToString:@"User"]) return YES;
		if ([applicationType isEqualToString:@"System"]) return NO;
	}
	NSString *path = application.bundleURL.path;
	return [path containsString:@"/var/containers/Bundle/Application/"];
}

- (void)appendApplicationSpecifiersToArray:(NSMutableArray *)specifiers
{
	[self appendGroupNamed:@"Applications" applications:self.applications toArray:specifiers];
}

- (void)appendGroupNamed:(NSString *)name applications:(NSArray<LSApplicationProxy *> *)applications
	toArray:(NSMutableArray *)specifiers
{
	if (applications.count == 0) return;
	PSSpecifier *group = [PSSpecifier groupSpecifierWithName:name];
	[specifiers addObject:group];
	for (LSApplicationProxy *application in applications) {
		NSString *title = application.localizedName.length > 0
			? application.localizedName
			: application.bundleIdentifier;
		PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:title
			target:self
			set:@selector(setPreferenceValue:specifier:)
			get:@selector(readPreferenceValue:)
			detail:nil
			cell:PSSwitchCell
			edit:nil];
		[specifier setProperty:application.bundleIdentifier forKey:@"bundleIdentifier"];
		[specifier setProperty:kPPPreferencesDomain forKey:@"defaults"];
		[specifier setProperty:[kPPEnabledKeyPrefix
			stringByAppendingString:application.bundleIdentifier] forKey:@"key"];
		[specifier setProperty:@NO forKey:@"default"];
		[specifiers addObject:specifier];
	}
}

@end

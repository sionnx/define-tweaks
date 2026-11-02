//
//  ASTCModels.m
//  AppStoreControl
//

#import "ASTCModels.h"
#import <UIKit/UIKit.h>

static NSComparisonResult ASTCCompareVersionStrings(NSString *lhs, NSString *rhs)
{
    if (lhs.length == 0 && rhs.length == 0) {
        return NSOrderedSame;
    }
    if (lhs.length == 0) {
        return NSOrderedAscending;
    }
    if (rhs.length == 0) {
        return NSOrderedDescending;
    }

    NSArray<NSString *> *left = [lhs componentsSeparatedByString:@"."];
    NSArray<NSString *> *right = [rhs componentsSeparatedByString:@"."];
    NSUInteger count = MAX(left.count, right.count);

    for (NSUInteger index = 0; index < count; index++) {
        NSString *leftComponent = index < left.count ? left[index] : @"0";
        NSString *rightComponent = index < right.count ? right[index] : @"0";

        // Split non-numeric suffixes ("1a" vs "1b") so they still compare in a
        // deterministic way.
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        NSString *leftNumber = [leftComponent componentsSeparatedByCharactersInSet:nonDigits].firstObject;
        NSString *rightNumber = [rightComponent componentsSeparatedByCharactersInSet:nonDigits].firstObject;
        NSInteger leftValue = leftNumber.length ? leftNumber.integerValue : 0;
        NSInteger rightValue = rightNumber.length ? rightNumber.integerValue : 0;

        if (leftValue < rightValue) {
            return NSOrderedAscending;
        }
        if (leftValue > rightValue) {
            return NSOrderedDescending;
        }
        if (![leftComponent isEqualToString:rightComponent]) {
            return [leftComponent compare:rightComponent options:NSNumericSearch];
        }
    }
    return NSOrderedSame;
}

@implementation ASTCVersion

- (BOOL)isCompatible
{
    if (self.minimumOSVersion.length == 0) {
        // Unknown requirements are assumed to be compatible; Apple still
        // validates the requested build and answers with an error when the
        // build cannot run on this device.
        return YES;
    }
    NSString *deviceVersion = [[UIDevice currentDevice] systemVersion];
    return ASTCCompareVersionStrings(self.minimumOSVersion, deviceVersion) != NSOrderedDescending;
}

- (NSComparisonResult)compareVersion:(ASTCVersion *)other
{
    NSComparisonResult result = ASTCCompareVersionStrings(self.displayVersion, other.displayVersion);
    if (result == NSOrderedSame) {
        // Fall back to the external identifier so ordering stays stable.
        NSComparisonResult extResult = ASTCCompareVersionStrings(self.externalVersionId, other.externalVersionId);
        return extResult;
    }
    return result;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<ASTCVersion %@ ext=%@ minOS=%@ buyParams=%@>",
                                      self.displayVersion ?: @"?",
                                      self.externalVersionId ?: @"?",
                                      self.minimumOSVersion ?: @"?",
                                      self.buyParams.length ? @"yes" : @"no"];
}

@end

@implementation ASTCInstalledApp

- (NSString *)description
{
    return [NSString stringWithFormat:@"<ASTCInstalledApp %@ (%@) %@>", self.name, self.bundleId, self.version];
}

@end

@implementation ASTCProduct

- (instancetype)init
{
    self = [super init];
    if (self) {
        _versions = [NSMutableArray array];
    }
    return self;
}

- (ASTCVersion *)installedVersion
{
    if (self.installedDisplayVersion.length == 0) {
        return nil;
    }
    for (ASTCVersion *version in self.versions) {
        if ([version.displayVersion isEqualToString:self.installedDisplayVersion]) {
            return version;
        }
    }
    return nil;
}

@end

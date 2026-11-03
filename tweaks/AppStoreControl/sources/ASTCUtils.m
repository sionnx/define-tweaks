//
//  ASTCUtils.m
//  AppStoreControl
//
//  The account's country code comes from SSDevice. SKStorefront is not used:
//  on iOS 17.3 its countryCode is three letters ("HKG"), and the store lookup
//  takes two. The request is bounded by a deadline, then NSLocale applies.
//

#import "ASTCUtils.h"
#import "XLog.h"
#import "StoreServices.h"

static const NSTimeInterval kASTCStorefrontDeadline = 5.0;

/// The lowercase form of `value` if it is a two-letter code, otherwise nil.
static NSString *ASTCNormalizedCountryCode(id value)
{
    if (![value isKindOfClass:[NSString class]] || [value length] != 2) {
        return nil;
    }
    NSCharacterSet *nonLetters = [[NSCharacterSet letterCharacterSet] invertedSet];
    if ([value rangeOfCharacterFromSet:nonLetters].location != NSNotFound) {
        return nil;
    }
    return [value lowercaseString];
}

static NSString *ASTCSystemCountryCode(void)
{
    return ASTCNormalizedCountryCode([[NSLocale currentLocale] objectForKey:NSLocaleCountryCode]);
}

static void ASTCLoadDeviceCountryCode(void (^completion)(NSString *countryCode))
{
    @try {
        SSDevice *device = [(id)NSClassFromString(@"SSDevice") currentDevice];
        if (device) {
            [device sdk_loadStorefrontCountryCode:^(NSString *countryCode, NSError *error) {
                if (error) {
                    XLog(@"Utils", @"storefront: SSDevice failed: %@", error.localizedDescription);
                }
                completion(ASTCNormalizedCountryCode(countryCode));
            }];
            return;
        }
    } @catch (NSException *exception) {
        XLog(@"Utils", @"storefront: SSDevice raised %@", exception.reason);
    }
    completion(nil);
}

@implementation ASTCUtils

+ (void)loadStorefrontCountryCodeWithCompletion:(void (^)(NSString *countryCode))completion
{
    NSObject *lock = [NSObject new];
    __block BOOL finished = NO;
    // First call wins, so a result arriving after the deadline is dropped.
    void (^finish)(NSString *, NSString *) = ^(NSString *accountCode, NSString *accountSource) {
        @synchronized (lock) {
            if (finished) {
                return;
            }
            finished = YES;
        }
        NSString *systemCode = ASTCSystemCountryCode();
        NSString *countryCode = accountCode ?: systemCode ?: @"us";
        NSString *source = accountCode ? accountSource : (systemCode ? @"NSLocale" : @"default");
        XLog(@"Utils", @"storefront cc=%@ source=%@ locale=%@", countryCode, source, systemCode);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(countryCode);
        });
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kASTCStorefrontDeadline * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        finish(nil, nil);
    });
    ASTCLoadDeviceCountryCode(^(NSString *deviceCode) {
        finish(deviceCode, @"SSDevice");
    });
}

@end

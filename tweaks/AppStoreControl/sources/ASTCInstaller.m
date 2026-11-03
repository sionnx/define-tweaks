#import "ASTCInstaller.h"
#import "ASTCStoreServices.h"
#import "ASTCStoreClient.h"
#import "ASTCLog.h"

@implementation ASTCInstaller

+ (instancetype)sharedInstance
{
    static ASTCInstaller *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ASTCInstaller alloc] init];
    });
    return instance;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"

/// Polls appstored for the installed external version identifier until it
/// matches, so the caller learns whether the requested build actually landed.
- (void)waitForInstalledVersion:(ASTCVersion *)version
                       bundleID:(NSString *)bundleId
                        timeout:(NSTimeInterval)timeout
                     completion:(void (^)(BOOL matched))completion
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    __block void (^poll)(void);
    __weak typeof(self) weakSelf = self;
    poll = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        ASTCStoreClient *client = [ASTCStoreClient sharedInstance];
        [client refreshInstalledInfoForBundleID:bundleId completion:^(NSDictionary *info) {
            NSString *installedExternal = [client externalVersionIDForBundleID:bundleId];
            ASTCLog(@"verify %@: installed version=%@ ext=%@ wanted=%@",
                   bundleId, [client installedVersionForBundleID:bundleId],
                   installedExternal, version.externalVersionId);
            if ([installedExternal isEqualToString:version.externalVersionId]) {
                ASTCLog(@"install verified: %@ now at %@ (%@)", bundleId, version.displayVersion, installedExternal);
                if (completion) {
                    completion(YES);
                }
                return;
            }
            if ([deadline timeIntervalSinceNow] <= 0) {
                ASTCLog(@"install verification timed out: %@ still at %@ (wanted %@)",
                       bundleId, installedExternal, version.externalVersionId);
                if (completion) {
                    completion(NO);
                }
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                poll();
            });
        }];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        poll();
    });
}
#pragma clang diagnostic pop

- (void)installVersion:(ASTCVersion *)version
             ofProduct:(ASTCProduct *)product
            completion:(ASTCInstallResultHandler)completion
{
    if (!version || product.adamId.length == 0 || product.bundleId.length == 0) {
        if (completion) {
            completion([NSError errorWithDomain:@"to.define.appstorecontrol.installer"
                                           code:1
                                       userInfo:@{NSLocalizedDescriptionKey : @"Invalid version or app."}]);
        }
        return;
    }

    NSString *displayName = product.name ?: product.bundleId;
    [[ASTCStoreClient sharedInstance] refreshInstalledInfoForBundleID:product.bundleId completion:nil];
    ASTCLog(@"install request: %@ %@ (%@); installed is %@",
           displayName, version.displayVersion, version.externalVersionId,
           [[ASTCStoreClient sharedInstance] installedVersionForBundleID:product.bundleId] ?: @"unknown");

    [self installWithLocalRedownloadPath:version product:product completion:completion];
}

- (void)installWithLocalRedownloadPath:(ASTCVersion *)version
                               product:(ASTCProduct *)product
                            completion:(ASTCInstallResultHandler)completion
{
    __weak typeof(self) weakSelf = self;
    [[ASTCStoreServices sharedInstance] installVersionUsingLocalRedownloadParameters:version
                                                                          forAdamID:product.adamId
                                                                           bundleID:product.bundleId
                                                                         completion:^(NSError *localError) {
        // Without a response the store may have started the download, so a second
        // request could download the app twice.
        BOOL noResponse = [localError.domain isEqualToString:@"to.define.appstorecontrol.store"]
            && localError.code == ASTCStoreNoResponseErrorCode;
        if (localError && !noResponse) {
            ASTCLog(@"local redownload install unavailable: %@", localError.localizedDescription);
            [weakSelf installWithPurchasePath:version product:product completion:completion];
            return;
        }
        if (noResponse) {
            ASTCLog(@"local redownload install got no response; not sending another request");
        }
        if (completion) {
            completion(nil);
        }
        // The download keeps running in App Store. Large apps take a while, and
        // this result is only logged.
        [weakSelf waitForInstalledVersion:version
                                 bundleID:product.bundleId
                                  timeout:600
                               completion:nil];
    }];
}

/// Last resort: real purchase-shaped install (appstored purchase path). This
/// one can prompt for account confirmation, but it honours appExtVrsId.
- (void)installWithPurchasePath:(ASTCVersion *)version
                        product:(ASTCProduct *)product
                     completion:(ASTCInstallResultHandler)completion
{
    __weak typeof(self) weakSelf = self;
    [[ASTCStoreServices sharedInstance] installVersion:version
                                            forAdamID:product.adamId
                                   pricingParameters:@"STDQ"
                                          completion:^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (error) {
            if (completion) {
                completion(error);
            }
            return;
        }
        [strongSelf waitForInstalledVersion:version
                                   bundleID:product.bundleId
                                    timeout:180
                                 completion:^(BOOL matched) {
            if (completion) {
                if (matched) {
                    completion(nil);
                } else {
                    completion([NSError errorWithDomain:@"to.define.appstorecontrol.installer"
                                                   code:2
                                               userInfo:@{NSLocalizedDescriptionKey :
                                                   @"App Store accepted the download but the requested build did not install. Apple substituted a different build."}]);
                }
            }
        }];
    }];
}

@end

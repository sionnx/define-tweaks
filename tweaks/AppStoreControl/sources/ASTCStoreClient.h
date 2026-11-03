//
//  ASTCStoreClient.h
//  AppStoreControl
//
//  High level client used by the UI: resolves product metadata from Apple's
//  public store lookup, enumerates the app's build identifiers through
//  StoreServices and resolves each identifier to a display version.
//

#import <Foundation/Foundation.h>
#import "ASTCModels.h"

/// `versions` is a snapshot of every version known so far, newest first, and
/// `product` carries the store metadata needed to install one of them.
typedef void (^ASTCProductProgressHandler)(NSUInteger resolved, NSUInteger total, ASTCProduct *product,
                                          NSArray<ASTCVersion *> *versions);
typedef void (^ASTCProductHandler)(ASTCProduct *product, NSError *error);
typedef void (^ASTCAdamIDHandler)(NSString *adamId, NSString *bundleId, NSError *error);

extern NSString *const ASTCStoreClientErrorDomain;
/// The app is not installed, or its install state could not be determined, so
/// no version lookup ran. The error's description is the text to show.
static const NSInteger ASTCStoreClientInstallStateErrorCode = 20;

@interface ASTCStoreClient : NSObject

+ (instancetype)sharedInstance;

/// Fetch metadata plus the resolved version list for an app. `progress` is
/// called first with the cached versions (before any store request), then
/// after every probe; it may be called on a background queue.
- (void)fetchProductForAdamID:(NSString *)adamId
                     progress:(ASTCProductProgressHandler)progress
                   completion:(ASTCProductHandler)completion;

/// Stops the running version lookup of an app: no new store request is sent and
/// the builds resolved so far are written to the cache. A request already in
/// flight still finishes.
- (void)cancelVersionLookupForAdamID:(NSString *)adamId;

/// Resolve the numeric App Store identifier of an installed app.
- (void)resolveAdamIDForBundleID:(NSString *)bundleId completion:(ASTCAdamIDHandler)completion;

/// Version string of the installed app, nil when not installed.
- (NSString *)installedVersionForBundleID:(NSString *)bundleId;
/// Apple external version identifier of the installed build, when it can be
/// read from the local app metadata.
- (NSString *)externalVersionIDForBundleID:(NSString *)bundleId;

/// Installed user apps, sorted by name. Entries are ASTCInstalledApp objects
/// with bundleId/name/version properties (see the .m implementation).
- (NSArray *)installedApps;

/// Drop cached version data for one app (or everything when nil).
- (void)clearSkippedBuildsForAdamID:(NSString *)adamId;
- (void)clearCacheForAdamID:(NSString *)adamId;

/// Asks appstored for the installed version / external version identifier of
/// one app and updates the cache.
- (void)refreshInstalledInfoForBundleID:(NSString *)bundleId
                             completion:(void (^)(NSDictionary *info))completion;

@end

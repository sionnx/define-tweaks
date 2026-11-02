//
//  ASTCStoreServices.h
//  AppStoreControl
//
//  Runtime bridge to Apple's private StoreServices / AppStoreDaemon machinery.
//  The tweak lives inside the App Store process, so it inherits the App Store's
//  Store account, cookies and entitlements.
//
//   * Version lookup uses SSURLConnectionRequest: plain HTTP sent by itunesstored,
//     with no SSPurchase. The commerce plist's
//     `softwareVersionExternalIdentifiers` array is the list of builds. When the
//     store answers with a Buy action for a free redownload of the same app, that
//     action is followed once with a native SSPurchaseRequest that creates no
//     downloads. Any other authorization dialog stops the lookup.
//
//   * Installing a specific build uses purchase-shaped requests with
//     createsDownloads/createsJobs/createsInstallJobs enabled. appstored then
//     downloads Apple's signed package for that exact version and installs it
//     like a normal App Store download.
//

#import <Foundation/Foundation.h>
#import "ASTCModels.h"

/// Code of errors that stop a version lookup: the store wants an authorization
/// that cannot be followed safely, or the native request limit was reached.
static const NSInteger ASTCStoreLookupStoppedErrorCode = 15;

/// Result of Apple's commerce response for one app: every build identifier
/// Apple still serves, oldest first, plus the metadata of the current build.
@interface ASTCIdentifierList : NSObject

@property (nonatomic, copy) NSArray<NSString *> *identifiers;
@property (nonatomic, copy) NSString *latestDisplayVersion;
@property (nonatomic, copy) NSString *latestExternalVersionId;
@property (nonatomic, copy) NSString *minimumOSVersion;
/// Display versions Apple already provides for some builds (delta packages).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *displayVersionsByExternalId;

@end

typedef void (^ASTCIdentifiersHandler)(ASTCIdentifierList *list, NSError *error);
typedef void (^ASTCVersionHandler)(ASTCVersion *version, NSError *error);
typedef void (^ASTCInstallHandler)(NSError *error);

/// StoreServices is not linked at build time (it is private and version
/// specific), the bridge resolves everything with objc_msgSend.
@interface ASTCStoreServices : NSObject

+ (instancetype)sharedInstance;

/// YES when the required StoreServices classes exist in this process.
+ (BOOL)isAvailable;

/// Fetch the external version identifiers for `adamId`, in Apple's order.
- (void)fetchVersionIdentifiersForAdamID:(NSString *)adamId
                              completion:(ASTCIdentifiersHandler)completion;

/// Resolve the display version and minimum OS version of one identifier.
/// `pricingParameters` only shapes the buy parameters kept for the install.
- (void)resolveVersionForAdamID:(NSString *)adamId
                     externalID:(NSString *)externalID
              pricingParameters:(NSString *)pricingParameters
                     completion:(ASTCVersionHandler)completion;

/// Install using the account's local redownload identity, with appExtVrsId
/// rewritten to the chosen build. This path keeps the store quiet (no purchase
/// prompt) because appstored recognises the account's own redownload params.
- (void)installVersionUsingLocalRedownloadParameters:(ASTCVersion *)version
                                          forAdamID:(NSString *)adamId
                                           bundleID:(NSString *)bundleId
                                         completion:(ASTCInstallHandler)completion;

/// Silent install through appstored's install-apps service (the API App Store
/// and MDM use for initial content downloads). It takes the item id plus an
/// explicit external version id, so no purchase sheet should appear.
- (BOOL)installSilentlyWithInstallApps:(ASTCVersion *)version
                             forAdamID:(NSString *)adamId
                              bundleID:(NSString *)bundleId
                        displayVersion:(NSString *)displayVersion
                            completion:(ASTCInstallHandler)completion;

/// Ask appstored to download and install the given version.
- (void)installVersion:(ASTCVersion *)version
              forAdamID:(NSString *)adamId
    pricingParameters:(NSString *)pricingParameters
           completion:(ASTCInstallHandler)completion;


@end

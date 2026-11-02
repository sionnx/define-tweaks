//
//  ASTCModels.h
//  AppStoreControl
//
//  Model objects shared by the store client, the version chooser and the
//  installer.
//

#import <Foundation/Foundation.h>

/// One downloadable App Store version of an app.
@interface ASTCVersion : NSObject

/// Apple's external version identifier (the `appExtVrsId` buy parameter).
/// This is what makes it possible to ask the store for a specific build.
@property (nonatomic, copy) NSString *externalVersionId;
/// Human readable version, e.g. "12.4.1".
@property (nonatomic, copy) NSString *displayVersion;
/// The build's CFBundleVersion, e.g. "81055002", nil when unknown.
@property (nonatomic, copy) NSString *bundleVersion;
/// Size in bytes, 0 when unknown.
@property (nonatomic, assign) long long fileSize;
/// Minimum iOS version required by this build, nil when unknown.
@property (nonatomic, copy) NSString *minimumOSVersion;
/// Full buy parameter string for this build when the store provided one.
@property (nonatomic, copy) NSString *buyParams;
/// Signed IPA URL from the probe response. Short-lived, never cached.
@property (nonatomic, strong) NSURL *packageURL;

/// YES when `minimumOSVersion` is lower or equal to the running iOS version,
/// or when the minimum OS version is unknown.
@property (nonatomic, readonly, getter=isCompatible) BOOL compatible;
/// YES when this is the version currently installed on the device.
@property (nonatomic, assign, getter=isInstalled) BOOL installed;

/// Semantic comparison of `displayVersion` strings ("1.10" > "1.9").
- (NSComparisonResult)compareVersion:(ASTCVersion *)other;

@end

/// An installed user app, as listed by MobileCoreServices.
@interface ASTCInstalledApp : NSObject

@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *version;
/// Numeric App Store identifier when known.
@property (nonatomic, copy) NSString *adamId;

@end

/// An App Store product with the versions the tweak knows about.
@interface ASTCProduct : NSObject

/// Numeric App Store identifier, e.g. "284882215".
@property (nonatomic, copy) NSString *adamId;
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *iconURLString;
/// Version string of the most recent App Store build.
@property (nonatomic, copy) NSString *latestDisplayVersion;
/// Version string currently installed on the device, nil when not installed.
@property (nonatomic, copy) NSString *installedDisplayVersion;
/// Apple's external version identifier of the installed build, when known.
@property (nonatomic, copy) NSString *installedExternalVersionId;
@property (nonatomic, copy) NSString *minimumOSVersion;
@property (nonatomic, copy) NSString *whatsNew;
/// Pricing bucket used by the commerce endpoint ("STDQ" / "STDRDL").
@property (nonatomic, copy) NSString *pricingParameters;

/// Number of builds Apple lists for the app, resolved or not.
@property (nonatomic, assign) NSUInteger totalVersionCount;

/// ASTCVersion objects, newest first.
@property (nonatomic, strong) NSMutableArray<ASTCVersion *> *versions;

- (ASTCVersion *)installedVersion;

@end

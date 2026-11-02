//
//  ASTCStoreClient.m
//  AppStoreControl
//

#import "ASTCStoreClient.h"
#import "ASTCStoreServices.h"
#import "ASTCPackageInfoReader.h"
#import "ASTCLog.h"
#import "ASTCUtils.h"

#import <dlfcn.h>
#import <objc/message.h>

NSString *const ASTCStoreClientErrorDomain = @"to.define.appstorecontrol.client";

typedef NS_ENUM(NSInteger, ASTCInstallState) {
    ASTCInstallStateUnknown,
    ASTCInstallStateNotInstalled,
    ASTCInstallStateInstalled,
};

static NSError *ASTCClientError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:ASTCStoreClientErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @"Request failed"}];
}

#pragma mark - Local app queries (MobileCoreServices)

static id ASTCDefaultWorkspace(void)
{
    static Class workspaceClass;
    static id workspace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!workspaceClass) {
            dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
            workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        }
        if ([workspaceClass respondsToSelector:NSSelectorFromString(@"defaultWorkspace")]) {
            workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, NSSelectorFromString(@"defaultWorkspace"));
        }
    });
    return workspace;
}

/// applicationProxyForIdentifier: is a class method of LSApplicationProxy.
static id ASTCApplicationProxy(NSString *bundleId)
{
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (bundleId.length == 0 || ![proxyClass respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, selector, bundleId);
}

static NSString *ASTCValue(id object, NSString *key)
{
    @try {
        id value = [object valueForKey:key];
        if ([value isKindOfClass:[NSString class]] && [value length]) {
            return value;
        }
        return nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSNumber *ASTCNumber(id object, NSString *key)
{
    @try {
        id value = [object valueForKey:key];
        return [value isKindOfClass:[NSNumber class]] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}


#pragma mark - Version cache helpers

static NSString *ASTCCacheDirectory(void)
{
    static NSString *directory;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString *base = paths.firstObject ?: @"/tmp";
        directory = [base stringByAppendingPathComponent:@"AppStoreControl"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
    });
    return directory;
}

static NSString *ASTCCachePathForAdamID(NSString *adamId)
{
    return [ASTCCacheDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"versions-%@.plist", adamId]];
}

static void ASTCWriteCache(NSDictionary *cache, NSString *adamId)
{
    if (adamId.length == 0 || ![cache isKindOfClass:[NSDictionary class]]) {
        return;
    }
    [cache writeToFile:ASTCCachePathForAdamID(adamId) atomically:YES];
}

/// Returns the product's versions deduplicated, newest first, with the
/// installed build marked. Does not modify `product.versions`.
static NSArray<ASTCVersion *> *ASTCSortedVersions(ASTCProduct *product)
{
    @synchronized(product.versions) {
        NSMutableDictionary<NSString *, ASTCVersion *> *unique = [NSMutableDictionary dictionary];
        for (ASTCVersion *version in product.versions) {
            NSString *key = version.externalVersionId.length ? version.externalVersionId : version.displayVersion;
            if (key.length == 0) {
                continue;
            }
            ASTCVersion *existing = unique[key];
            // A cache-seeded entry and a fresh probe can share a key; keep the probe's build number.
            if (!existing || existing.displayVersion.length == 0
                || (existing.bundleVersion.length == 0 && version.bundleVersion.length > 0)) {
                unique[key] = version;
            }
        }
        NSArray<ASTCVersion *> *sorted = [unique.allValues sortedArrayUsingComparator:^NSComparisonResult(ASTCVersion *lhs, ASTCVersion *rhs) {
            return [rhs compareVersion:lhs];
        }];
        for (ASTCVersion *version in sorted) {
            // The version ID identifies a build exactly; display versions can repeat.
            version.installed = product.installedExternalVersionId.length
                ? [version.externalVersionId isEqualToString:product.installedExternalVersionId]
                : (product.installedDisplayVersion.length
                   && [version.displayVersion isEqualToString:product.installedDisplayVersion]);
        }
        return sorted;
    }
}

/// Sorts and deduplicates the resolved list and marks the installed build.
static void ASTCFinishProduct(ASTCProduct *product)
{
    NSArray<ASTCVersion *> *sorted = ASTCSortedVersions(product);
    @synchronized(product.versions) {
        [product.versions setArray:sorted];
    }
}

/// YES when the store answered and refused the build (it is no longer
/// served), as opposed to a transport failure worth retrying later.
static BOOL ASTCIsStoreRefusal(NSError *error)
{
    return [error.domain isEqualToString:@"SSServerErrorDomain"]
        || ([error.domain isEqualToString:@"to.define.appstorecontrol.store"] && error.code == 11);
}

#pragma mark - Identifier resolution

/// Resolves identifiers one at a time: the commerce endpoint rate limits
/// bursts. Implemented as a small state machine so it does not need a recursive block.
@interface ASTCIdentifierResolver : NSObject
@property (nonatomic, strong) ASTCProduct *product;
@property (nonatomic, copy) NSString *pricingParameters;
@property (nonatomic, strong) NSArray<NSString *> *identifiers;
@property (nonatomic, strong) NSMutableArray<NSString *> *pending;
@property (nonatomic, strong) NSMutableDictionary *cache;
@property (nonatomic, strong) NSMutableDictionary *resolved;
@property (nonatomic, strong) NSMutableArray<NSString *> *skipped;
@property (nonatomic, copy) ASTCProductProgressHandler progress;
@property (nonatomic, copy) ASTCProductHandler completion;
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, assign) NSUInteger failureCount;
@property (nonatomic, assign) NSUInteger successCount;
@property (nonatomic, assign) NSUInteger consecutiveRefusals;
@property (nonatomic, assign) CFAbsoluteTime startTime;
/// Info.plist reads still in flight; the cache is written once they end.
@property (nonatomic, assign) NSUInteger pendingReads;
@property (nonatomic, assign) BOOL probingDone;
@property (nonatomic, strong) NSError *stopError;
@property (nonatomic, assign) BOOL finished;
- (void)start;
@end

@implementation ASTCIdentifierResolver

- (void)start
{
    self.startTime = CFAbsoluteTimeGetCurrent();
    [self resolveNext];
}

- (void)resolveNext
{
    if (self.index >= self.pending.count) {
        [self finish];
        return;
    }

    NSString *identifier = self.pending[self.index++];
    CFAbsoluteTime probeStart = CFAbsoluteTimeGetCurrent();
    __weak typeof(self) weakSelf = self;
    [[ASTCStoreServices sharedInstance] resolveVersionForAdamID:self.product.adamId
                                                    externalID:identifier
                                             pricingParameters:self.pricingParameters
                                                    completion:^(ASTCVersion *version, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        ASTCLog(@"probe %lu/%lu ext=%@ took %.2fs -> %@",
               (unsigned long)strongSelf.index, (unsigned long)strongSelf.pending.count, identifier,
               CFAbsoluteTimeGetCurrent() - probeStart,
               version.displayVersion.length ? version.displayVersion : @"failed");
        if (version.displayVersion.length) {
            strongSelf.successCount++;
            strongSelf.consecutiveRefusals = 0;
            NSMutableDictionary *entry = [@{@"displayVersion" : version.displayVersion,
                                            @"minimumOSVersion" : version.minimumOSVersion ?: @"",
                                            @"bundleVersion" : version.bundleVersion ?: @""} mutableCopy];
            if (version.minimumOSVersion.length || !version.packageURL) {
                // Nothing more to learn for this build.
                entry[@"minOSChecked"] = @YES;
            }
            @synchronized(strongSelf.resolved) {
                strongSelf.resolved[identifier] = entry;
            }
            @synchronized(strongSelf.product.versions) {
                [strongSelf.product.versions addObject:version];
            }
            if (!version.minimumOSVersion.length && version.packageURL) {
                [strongSelf readMinimumOSForVersion:version identifier:identifier];
            }
        } else {
            strongSelf.failureCount++;
            if ([error.domain isEqualToString:@"to.define.appstorecontrol.store"] && error.code == ASTCStoreLookupStoppedErrorCode) {
                strongSelf.stopError = error;
                [strongSelf finish];
                return;
            }
            [strongSelf.skipped addObject:identifier];
            if (ASTCIsStoreRefusal(error)) {
                strongSelf.consecutiveRefusals++;
                // Probes run newest to oldest and Apple stops serving builds
                // from the oldest end, so a refusal means every older build is
                // gone too. Require a success this run, or two refusals in a
                // row, so a signed-out session is not mistaken for that.
                if (strongSelf.successCount > 0 || strongSelf.consecutiveRefusals >= 2) {
                    [strongSelf skipBuildsOlderThan:identifier];
                    [strongSelf finish];
                    return;
                }
            }
        }
        if (strongSelf.progress) {
            strongSelf.progress(strongSelf.index, strongSelf.pending.count, strongSelf.product, ASTCSortedVersions(strongSelf.product));
        }
        // Give the store a moment between probes.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            typeof(strongSelf) innerSelf = strongSelf;
            [innerSelf resolveNext];
        });
    }];
}

/// Marks every unresolved build older than `identifier` as skipped.
/// `identifiers` is ordered oldest first.
- (void)skipBuildsOlderThan:(NSString *)identifier
{
    NSUInteger position = [self.identifiers indexOfObject:identifier];
    if (position == NSNotFound) {
        return;
    }
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < position; i++) {
        NSString *older = self.identifiers[i];
        @synchronized(self.resolved) {
            if ([self.resolved[older] isKindOfClass:[NSDictionary class]]) {
                continue;
            }
        }
        [self.skipped addObject:older];
        count++;
    }
    ASTCLog(@"ext=%@ is no longer served; skipping %lu older builds", identifier, (unsigned long)count);
}

/// Reads the build's Info.plist from its IPA (a few range requests against
/// Apple's CDN, not the rate-limited commerce endpoint), in parallel with the
/// remaining probes.
- (void)readMinimumOSForVersion:(ASTCVersion *)version identifier:(NSString *)identifier
{
    @synchronized(self) {
        self.pendingReads++;
    }
    [[ASTCPackageInfoReader sharedInstance] readInfoPlistAtURL:version.packageURL completion:^(NSDictionary *info, NSError *error) {
        NSString *minimumOS = [info[@"MinimumOSVersion"] isKindOfClass:[NSString class]] ? info[@"MinimumOSVersion"] : nil;
        version.minimumOSVersion = minimumOS;
        @synchronized(self.resolved) {
            NSMutableDictionary *entry = [self.resolved[identifier] mutableCopy];
            if (entry) {
                entry[@"minimumOSVersion"] = minimumOS ?: @"";
                // Transport errors are retried on the next open.
                if (info || !error || ![error.domain isEqualToString:NSURLErrorDomain]) {
                    entry[@"minOSChecked"] = @YES;
                }
                self.resolved[identifier] = entry;
            }
        }
        if (self.progress && minimumOS.length) {
            self.progress(self.index, self.pending.count, self.product, ASTCSortedVersions(self.product));
        }
        BOOL last = NO;
        @synchronized(self) {
            self.pendingReads--;
            last = self.pendingReads == 0 && self.probingDone;
        }
        if (last) {
            [self complete];
        }
    }];
}

- (void)finish
{
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - self.startTime;
    ASTCLog(@"probing took %.2fs: %lu probes, %lu failed, avg %.2fs/probe",
           elapsed, (unsigned long)self.index, (unsigned long)self.failureCount,
           self.index ? elapsed / self.index : 0);
    BOOL waiting = NO;
    @synchronized(self) {
        self.probingDone = YES;
        waiting = self.pendingReads > 0;
    }
    if (waiting) {
        ASTCLog(@"waiting for %lu Info.plist reads", (unsigned long)self.pendingReads);
        return;
    }
    [self complete];
}

/// Writes the cache and reports the result, once probes and reads are done.
- (void)complete
{
    @synchronized(self) {
        if (self.finished) {
            return;
        }
        self.finished = YES;
    }
    ASTCLog(@"version resolution took %.2fs including Info.plist reads", CFAbsoluteTimeGetCurrent() - self.startTime);
    @synchronized(self.resolved) {
        // Another chooser may have written the file while this one probed;
        // keep its entries instead of overwriting them with a smaller set.
        NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:ASTCCachePathForAdamID(self.product.adamId)];
        NSMutableDictionary *merged = [onDisk[@"resolved"] isKindOfClass:[NSDictionary class]]
            ? [onDisk[@"resolved"] mutableCopy] : [NSMutableDictionary dictionary];
        [merged addEntriesFromDictionary:self.resolved];
        self.cache[@"resolved"] = merged;
    }
    if (self.skipped.count) {
        NSMutableSet *skipped = [NSMutableSet setWithArray:self.cache[@"skipped"] ?: @[]];
        [skipped addObjectsFromArray:self.skipped];
        self.cache[@"skipped"] = skipped.allObjects;
    }
    ASTCWriteCache(self.cache, self.product.adamId);
    if (self.product.versions.count == 0) {
        if (self.completion) {
            self.completion(self.product, self.stopError ?: ASTCClientError(9, [NSString stringWithFormat:
                @"No versions could be resolved from the App Store (%lu failed).",
                (unsigned long)self.failureCount]));
        }
        return;
    }
    ASTCFinishProduct(self.product);
    if (self.completion) {
        self.completion(self.product, self.stopError);
    }
}

@end

@implementation ASTCStoreClient {
    NSMutableSet *_activeResolvers;
    NSMutableDictionary<NSString *, NSDictionary *> *_installedInfo;
}

+ (instancetype)sharedInstance
{
    static ASTCStoreClient *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ASTCStoreClient alloc] init];
    });
    return instance;
}

#pragma mark - Lifecycle

- (NSMutableSet *)activeResolvers
{
    if (!_activeResolvers) {
        _activeResolvers = [NSMutableSet set];
    }
    return _activeResolvers;
}

#pragma mark - Installed app metadata

- (NSMutableDictionary<NSString *, NSDictionary *> *)installedInfoCache
{
    if (!_installedInfo) {
        _installedInfo = [NSMutableDictionary dictionary];
    }
    return _installedInfo;
}

/// App Store keeps the installed build's external version identifier in
/// appstored, not in a readable file next to the app bundle (the App Store
/// sandbox cannot read other apps' iTunesMetadata.plist).
- (void)refreshInstalledInfoForBundleID:(NSString *)bundleId completion:(void (^)(NSDictionary *info))completion
{
    [self queryInstallStateForBundleID:bundleId completion:^(__unused ASTCInstallState state, NSDictionary *info) {
        if (completion) {
            completion(info);
        }
    }];
}

/// `info` is nil unless appstored reported a version or identifier. Only a
/// completed query that found no app means "not installed"; a failed query says
/// nothing about the app, so it leaves the cache alone.
- (void)queryInstallStateForBundleID:(NSString *)bundleId
                          completion:(void (^)(ASTCInstallState state, NSDictionary *info))completion
{
    if (bundleId.length == 0) {
        completion(ASTCInstallStateUnknown, nil);
        return;
    }

    Class queryClass = NSClassFromString(@"ASDAppQuery");
    if (!queryClass) {
        completion(ASTCInstallStateUnknown, nil);
        return;
    }

    id query = ((id (*)(id, SEL, id))objc_msgSend)(queryClass, NSSelectorFromString(@"queryForBundleIDs:"), @[bundleId]);
    SEL selector = NSSelectorFromString(@"executeQueryWithResultHandler:");
    if (!query || ![query respondsToSelector:selector]) {
        completion(ASTCInstallStateUnknown, nil);
        return;
    }

    __block BOOL finished = NO;
    void (^handler)(NSArray *, NSError *) = ^(NSArray *apps, NSError *error) {
        if (finished) {
            return;
        }
        finished = YES;
        BOOL found = NO;
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        for (id app in apps) {
            @try {
                NSString *appBundle = [app valueForKey:@"bundleID"];
                if (bundleId.length && appBundle.length && ![appBundle isEqualToString:bundleId]) {
                    continue;
                }
                found = YES;
                NSString *version = [app valueForKey:@"bundleShortVersion"];
                NSNumber *externalId = [app valueForKey:@"storeExternalVersionID"];
                if ([version isKindOfClass:[NSString class]] && version.length) {
                    info[@"version"] = version;
                }
                if ([externalId isKindOfClass:[NSNumber class]] && externalId.longLongValue != 0) {
                    info[@"ext"] = [externalId description];
                }
            } @catch (__unused NSException *exception) {
            }
        }
        ASTCInstallState state = error ? ASTCInstallStateUnknown
                                      : (found ? ASTCInstallStateInstalled : ASTCInstallStateNotInstalled);
        ASTCLog(@"appstored info for %@: %@ (state=%ld error=%@)", bundleId, info, (long)state, error);
        if (info.count) {
            self.installedInfoCache[bundleId] = info;
        } else if (state == ASTCInstallStateNotInstalled) {
            [self.installedInfoCache removeObjectForKey:bundleId];
        }
        completion(state, info.count ? info : nil);
    };
    ((void (*)(id, SEL, id))objc_msgSend)(query, selector, handler);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!finished) {
            finished = YES;
            ASTCLog(@"appstored info query timed out for %@", bundleId);
            completion(ASTCInstallStateUnknown, nil);
        }
    });
}

- (NSDictionary *)cachedInstalledInfoForBundleID:(NSString *)bundleId
{
    return bundleId.length ? self.installedInfoCache[bundleId] : nil;
}

#pragma mark - Local apps

- (NSArray *)installedApps
{
    id workspace = ASTCDefaultWorkspace();
    if (!workspace) {
        return @[];
    }
    NSArray *proxies = nil;
    @try {
        proxies = ((id (*)(id, SEL))objc_msgSend)(workspace, NSSelectorFromString(@"allInstalledApplications"));
    } @catch (__unused NSException *exception) {
        return @[];
    }
    if (![proxies isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<ASTCInstalledApp *> *apps = [NSMutableArray array];
    for (id proxy in proxies) {
        NSString *bundleId = ASTCValue(proxy, @"bundleIdentifier");
        if (bundleId.length == 0) {
            continue;
        }
        // Only user apps can be downloaded from the store again.
        NSString *type = ASTCValue(proxy, @"applicationType");
        if (type.length && ![type isEqualToString:@"User"]) {
            continue;
        }
        if ([bundleId hasPrefix:@"com.apple."]) {
            continue;
        }
        ASTCInstalledApp *app = [ASTCInstalledApp new];
        app.bundleId = bundleId;
        app.name = ASTCValue(proxy, @"localizedName") ?: ASTCValue(proxy, @"itemName") ?: bundleId;
        app.version = ASTCValue(proxy, @"shortVersionString");
        NSNumber *itemID = ASTCNumber(proxy, @"itemID");
        if (itemID.longLongValue != 0) {
            app.adamId = itemID.stringValue;
        }
        [apps addObject:app];
    }

    [apps sortUsingComparator:^NSComparisonResult(ASTCInstalledApp *lhs, ASTCInstalledApp *rhs) {
        return [lhs.name localizedCaseInsensitiveCompare:rhs.name];
    }];
    return apps;
}

- (NSString *)installedVersionForBundleID:(NSString *)bundleId
{
    return [self cachedInstalledInfoForBundleID:bundleId][@"version"];
}

- (NSString *)externalVersionIDForBundleID:(NSString *)bundleId
{
    return [self cachedInstalledInfoForBundleID:bundleId][@"ext"];
}

#pragma mark - Networking

- (NSURLSession *)session
{
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 30;
        configuration.HTTPAdditionalHeaders = @{
            @"Accept" : @"application/json",
            @"User-Agent" : @"AppStore/3.0 iOS/17.0 (21A329)",
        };
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

- (void)getJSONAtURL:(NSURL *)url completion:(void (^)(id json, NSError *error))completion
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        if (!data.length) {
            completion(nil, ASTCClientError(1, @"Apple returned an empty response."));
            return;
        }
        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (!json) {
            completion(nil, jsonError ?: ASTCClientError(2, @"Apple returned an unexpected response."));
            return;
        }
        completion(json, nil);
    }] resume];
}

#pragma mark - Product lookup

/// Offers from the MZStorePlatform lookup contain the buy parameters the
/// commerce endpoint wants (`pricingParameters=STDQ`, `appExtVrsId=...`).
- (ASTCProduct *)parseLookupResult:(NSDictionary *)result adamId:(NSString *)adamId
{
    if (![result isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    ASTCProduct *product = [ASTCProduct new];
    product.adamId = adamId;
    product.bundleId = result[@"bundleId"];
    product.name = result[@"name"];
    product.whatsNew = [result[@"whatsNew"] isKindOfClass:[NSDictionary class]]
        ? result[@"whatsNew"][@"text"]
        : nil;
    id artwork = result[@"iconArtwork"] ?: result[@"artwork"];
    if ([artwork isKindOfClass:[NSDictionary class]]) {
        NSString *raw = artwork[@"url"];
        if ([raw isKindOfClass:[NSString class]]) {
            // Artwork URLs are templates: {w}x{h}{c}.{f}
            product.iconURLString = [raw stringByReplacingOccurrencesOfString:@"{w}x{h}{c}.{f}" withString:@"120x120bb.png"];
        }
    }
    if ([result[@"minimumOSVersion"] isKindOfClass:[NSString class]]) {
        product.minimumOSVersion = result[@"minimumOSVersion"];
    }

    NSString *pricingParameters = nil;
    NSArray *offers = result[@"offers"];
    if ([offers isKindOfClass:[NSArray class]]) {
        for (NSDictionary *offer in offers) {
            if (![offer isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *buyParams = offer[@"buyParams"];
            if (![buyParams isKindOfClass:[NSString class]]) {
                continue;
            }
            NSDictionary *version = offer[@"version"];
            NSString *displayVersion = nil;
            NSString *externalVersionId = nil;
            if ([version isKindOfClass:[NSDictionary class]]) {
                displayVersion = version[@"display"];
                id externalId = version[@"externalId"];
                if ([externalId isKindOfClass:[NSNumber class]] || [externalId isKindOfClass:[NSString class]]) {
                    externalVersionId = [externalId description];
                }
            }

            ASTCVersion *parsed = [ASTCVersion new];
            parsed.buyParams = buyParams;
            parsed.displayVersion = displayVersion;
            parsed.externalVersionId = externalVersionId;
            NSArray *assets = offer[@"assets"];
            if ([assets isKindOfClass:[NSArray class]] && assets.count) {
                NSNumber *size = assets.firstObject[@"size"];
                if ([size isKindOfClass:[NSNumber class]]) {
                    parsed.fileSize = size.longLongValue;
                }
            }
            if (parsed.displayVersion.length) {
                [product.versions addObject:parsed];
                if (!product.latestDisplayVersion || [parsed.displayVersion compare:product.latestDisplayVersion options:NSNumericSearch] == NSOrderedDescending) {
                    product.latestDisplayVersion = parsed.displayVersion;
                }
            }

            if (!pricingParameters) {
                NSRange range = [buyParams rangeOfString:@"pricingParameters="];
                if (range.location != NSNotFound) {
                    NSString *tail = [buyParams substringFromIndex:NSMaxRange(range)];
                    NSString *value = [tail componentsSeparatedByString:@"&"].firstObject;
                    if (value.length) {
                        pricingParameters = value;
                    }
                }
            }
        }
    }

    product.installedDisplayVersion = nil; // filled in by the caller
    if (pricingParameters.length == 0) {
        pricingParameters = @"STDQ";
    }
    // Stash the pricing bucket on the product via the latest version object so
    // the caller can reuse it without a second lookup.
    product.pricingParameters = pricingParameters;
    return product;
}

- (NSURL *)lookupURLWithAdamID:(NSString *)adamId bundleId:(NSString *)bundleId countryCode:(NSString *)cc
{
    if (adamId.length) {
        NSString *format = @"https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup?version=2&id=%@&p=offer&caller=MDM&platform=itunes&cc=%@";
        return [NSURL URLWithString:[NSString stringWithFormat:format, adamId, cc]];
    }
    NSString *format = @"https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup?version=2&bundleId=%@&p=offer&caller=MDM&platform=itunes&cc=%@";
    return [NSURL URLWithString:[NSString stringWithFormat:format, bundleId, cc]];
}

- (void)getLookupJSONWithAdamID:(NSString *)adamId
                       bundleId:(NSString *)bundleId
                     completion:(void (^)(id json, NSError *error))completion
{
    [ASTCUtils loadStorefrontCountryCodeWithCompletion:^(NSString *countryCode) {
        [self getJSONAtURL:[self lookupURLWithAdamID:adamId bundleId:bundleId countryCode:countryCode]
                completion:completion];
    }];
}

- (void)resolveAdamIDForBundleID:(NSString *)bundleId completion:(ASTCAdamIDHandler)completion
{
    if (bundleId.length == 0) {
        completion(nil, nil, ASTCClientError(3, @"A bundle identifier is required."));
        return;
    }
    // Local lookup first: installed Store apps know their item id.
    @try {
        NSNumber *itemID = ASTCNumber(ASTCApplicationProxy(bundleId), @"itemID");
        if (itemID.longLongValue != 0) {
            completion(itemID.stringValue, bundleId, nil);
            return;
        }
    } @catch (__unused NSException *exception) {
    }

    [self getLookupJSONWithAdamID:nil bundleId:bundleId completion:^(id json, NSError *error) {
        NSDictionary *results = json[@"results"];
        if (![results isKindOfClass:[NSDictionary class]]) {
            completion(nil, bundleId, error ?: ASTCClientError(4, @"App Store lookup returned no results."));
            return;
        }
        __block NSString *resolvedBundleId = nil;
        __block NSString *resolvedAdamId = nil;
        [results enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if (![value isKindOfClass:[NSDictionary class]]) {
                return;
            }
            NSString *candidateBundle = value[@"bundleId"];
            if ([candidateBundle isEqualToString:bundleId]) {
                resolvedAdamId = [key description];
                resolvedBundleId = candidateBundle;
                *stop = YES;
            }
        }];
        if (resolvedAdamId.length) {
            completion(resolvedAdamId, resolvedBundleId, nil);
        } else {
            completion(nil, bundleId, ASTCClientError(5, @"App Store lookup did not return this app."));
        }
    }];
}

#pragma mark - Version cache

- (NSString *)cacheDirectory
{
    return ASTCCacheDirectory();
}

- (NSString *)cachePathForAdamID:(NSString *)adamId
{
    return ASTCCachePathForAdamID(adamId);
}

- (NSMutableDictionary *)loadCacheForAdamID:(NSString *)adamId
{
    NSString *path = [self cachePathForAdamID:adamId];
    NSDictionary *cached = [NSDictionary dictionaryWithContentsOfFile:path];
    return [cached isKindOfClass:[NSDictionary class]] ? [cached mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)saveCache:(NSDictionary *)cache forAdamID:(NSString *)adamId
{
    ASTCWriteCache(cache, adamId);
}

- (void)clearSkippedBuildsForAdamID:(NSString *)adamId
{
    NSMutableDictionary *cache = [self loadCacheForAdamID:adamId];
    if (cache[@"skipped"]) {
        [cache removeObjectForKey:@"skipped"];
        [self saveCache:cache forAdamID:adamId];
    }
}

- (void)clearCacheForAdamID:(NSString *)adamId
{
    NSFileManager *manager = [NSFileManager defaultManager];
    if (adamId.length) {
        [manager removeItemAtPath:[self cachePathForAdamID:adamId] error:NULL];
        return;
    }
    [manager removeItemAtPath:[self cacheDirectory] error:NULL];
}

#pragma mark - Product + versions

- (void)fetchProductForAdamID:(NSString *)adamId
                     progress:(ASTCProductProgressHandler)progress
                   completion:(ASTCProductHandler)completion
{
    if (adamId.length == 0) {
        completion(nil, ASTCClientError(6, @"An app identifier is required."));
        return;
    }

    [self getLookupJSONWithAdamID:adamId bundleId:nil completion:^(id json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSDictionary *results = json[@"results"];
        NSDictionary *result = [results isKindOfClass:[NSDictionary class]] ? results[adamId] : nil;
        ASTCProduct *product = [self parseLookupResult:result adamId:adamId];
        if (!product) {
            completion(nil, ASTCClientError(7, @"The App Store has no metadata for this app."));
            return;
        }
        // The store only serves the requested build of an installed app, so a
        // missing app gets no store request at all.
        [self queryInstallStateForBundleID:product.bundleId completion:^(ASTCInstallState state, __unused NSDictionary *info) {
            if (state != ASTCInstallStateInstalled) {
                ASTCLog(@"version lookup skipped for %@: reason=%@", product.bundleId,
                       state == ASTCInstallStateNotInstalled ? @"app not installed" : @"install state unknown");
                completion(product, ASTCClientError(ASTCStoreClientInstallStateErrorCode, state == ASTCInstallStateNotInstalled
                    ? @"Version history is only available for installed apps."
                    : @"Could not check whether this app is installed. Pull down to try again."));
                return;
            }
            if (!product.installedDisplayVersion && product.bundleId.length) {
                product.installedDisplayVersion = [self installedVersionForBundleID:product.bundleId];
            }
            if (!product.installedExternalVersionId && product.bundleId.length) {
                product.installedExternalVersionId = [self externalVersionIDForBundleID:product.bundleId];
            }
            ASTCLog(@"local app state: bundleId=%@ installedVersion=%@ installedExt=%@",
                   product.bundleId, product.installedDisplayVersion, product.installedExternalVersionId);
            [self fetchVersionsForProduct:product progress:progress completion:completion];
        }];
    }];
}

- (void)fetchVersionsForProduct:(ASTCProduct *)product
                       progress:(ASTCProductProgressHandler)progress
                     completion:(ASTCProductHandler)completion
{
    if (![ASTCStoreServices isAvailable]) {
        completion(product, ASTCClientError(8, @"The store services are unavailable in this process."));
        return;
    }

    NSString *pricingParameters = product.pricingParameters.length ? product.pricingParameters : @"STDQ";
    ASTCStoreServices *services = [ASTCStoreServices sharedInstance];
    NSMutableDictionary *cache = [self loadCacheForAdamID:product.adamId];

    // Build the versions we already know without contacting the store.
    ASTCProduct *cachedProduct = [ASTCProduct new];
    cachedProduct.installedDisplayVersion = product.installedDisplayVersion;
    cachedProduct.versions = [NSMutableArray array];
    NSDictionary *resolved = [cache[@"resolved"] isKindOfClass:[NSDictionary class]] ? cache[@"resolved"] : nil;
    [resolved enumerateKeysAndObjectsUsingBlock:^(NSString *externalId, NSDictionary *entry, BOOL *stop) {
        if (![entry isKindOfClass:[NSDictionary class]] || [entry[@"displayVersion"] length] == 0) {
            return;
        }
        ASTCVersion *version = [ASTCVersion new];
        version.externalVersionId = externalId;
        version.displayVersion = entry[@"displayVersion"];
        version.minimumOSVersion = [entry[@"minimumOSVersion"] length] ? entry[@"minimumOSVersion"] : nil;
        version.bundleVersion = [entry[@"bundleVersion"] length] ? entry[@"bundleVersion"] : nil;
        [cachedProduct.versions addObject:version];
    }];

    // Show the last session's resolved versions while the list loads.
    if (progress && cachedProduct.versions.count) {
        ASTCLog(@"showing %lu cached versions for %@", (unsigned long)cachedProduct.versions.count, product.adamId);
        progress(0, 0, product, ASTCSortedVersions(cachedProduct));
    }

    __weak typeof(self) weakSelf = self;
    [services fetchVersionIdentifiersForAdamID:product.adamId
                                    completion:^(ASTCIdentifierList *list, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (!list) {
            completion(product, error ?: ASTCClientError(9, @"Apple returned no version list."));
            return;
        }
        [strongSelf resolveIdentifiers:list
                               product:product
                     pricingParameters:pricingParameters
                                 cache:cache
                              progress:progress
                            completion:completion];
    }];
}

- (void)resolveIdentifiers:(ASTCIdentifierList *)list
                   product:(ASTCProduct *)product
         pricingParameters:(NSString *)pricingParameters
                     cache:(NSMutableDictionary *)cache
                  progress:(ASTCProductProgressHandler)progress
                completion:(ASTCProductHandler)completion
{
    // Never probe the whole history: popular apps have hundreds of builds and
    // every probe is a store round trip. The cache grows as the user browses.
    static const NSUInteger kASTCMaxProbes = 60;

    NSArray<NSString *> *identifiers = list.identifiers ?: @[];
    cache[@"identifiers"] = identifiers;
    product.totalVersionCount = identifiers.count;
    NSMutableDictionary *resolved = [cache[@"resolved"] isKindOfClass:[NSDictionary class]]
        ? [cache[@"resolved"] mutableCopy]
        : [NSMutableDictionary dictionary];

    void (^seed)(NSString *, NSString *, NSString *) = ^(NSString *externalId, NSString *displayVersion, NSString *minimumOS) {
        if (externalId.length == 0 || displayVersion.length == 0) {
            return;
        }
        // Keep the build number a previous probe found; seeds never carry one.
        NSDictionary *existing = [resolved[externalId] isKindOfClass:[NSDictionary class]] ? resolved[externalId] : nil;
        NSMutableDictionary *entry = [existing mutableCopy] ?: [NSMutableDictionary dictionary];
        entry[@"displayVersion"] = displayVersion;
        if (minimumOS.length) {
            entry[@"minimumOSVersion"] = minimumOS;
        }
        resolved[externalId] = entry;
    };
    // Entries missing the build number or the minimum OS check (seeded, or
    // cached by an older release) are listed right away but probed again so
    // the missing fields fill in.
    BOOL (^isComplete)(NSString *) = ^BOOL(NSString *externalId) {
        NSDictionary *entry = resolved[externalId];
        return [entry isKindOfClass:[NSDictionary class]] && [entry[@"bundleVersion"] length] > 0
            && [entry[@"minOSChecked"] boolValue];
    };

    // Apple tells us the current build in the identifier response, and the
    // installed build is known from the local app metadata: no probe needed.
    seed(list.latestExternalVersionId, list.latestDisplayVersion, list.minimumOSVersion);
    seed(product.installedExternalVersionId, product.installedDisplayVersion, nil);
    // The delta packages in the same response carry the display version of the
    // recent builds Apple still keeps deltas for.
    [list.displayVersionsByExternalId enumerateKeysAndObjectsUsingBlock:^(NSString *externalId, NSString *displayVersion, BOOL *stop) {
        seed(externalId, displayVersion, nil);
    }];

    // Seed from the disk cache so re-opening the chooser is instant.
    for (NSString *identifier in identifiers) {
        NSDictionary *entry = resolved[identifier];
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        ASTCVersion *version = [ASTCVersion new];
        version.externalVersionId = identifier;
        version.displayVersion = entry[@"displayVersion"];
        version.minimumOSVersion = entry[@"minimumOSVersion"];
        version.bundleVersion = [entry[@"bundleVersion"] length] ? entry[@"bundleVersion"] : nil;
        if (version.displayVersion.length) {
            [product.versions addObject:version];
        }
    }

    NSSet<NSString *> *skipped = [NSSet setWithArray:[cache[@"skipped"] isKindOfClass:[NSArray class]] ? cache[@"skipped"] : @[]];
    NSMutableArray<NSString *> *pending = [NSMutableArray array];
    // Apple returns softwareVersionExternalIdentifiers oldest first; users care
    // about the newest builds, so probe from the end of the array.
    for (NSString *identifier in [identifiers reverseObjectEnumerator]) {
        if (isComplete(identifier) || [skipped containsObject:identifier]) {
            continue;
        }
        [pending addObject:identifier];
        if (pending.count >= kASTCMaxProbes) {
            break;
        }
    }

    ASTCLog(@"version list for %@: total=%lu cached=%lu probing=%lu pricing=%@",
           product.adamId, (unsigned long)identifiers.count,
           (unsigned long)(identifiers.count - pending.count),
           (unsigned long)pending.count, pricingParameters);

    if (pending.count == 0) {
        [self finishProduct:product completion:completion];
        return;
    }

    if (progress) {
        progress(0, pending.count, product, ASTCSortedVersions(product));
    }

    ASTCIdentifierResolver *resolver = [ASTCIdentifierResolver new];
    resolver.skipped = [NSMutableArray array];
    resolver.product = product;
    resolver.pricingParameters = pricingParameters;
    resolver.identifiers = identifiers;
    resolver.pending = pending;
    resolver.cache = cache;
    resolver.resolved = resolved;
    resolver.progress = progress;

    __weak typeof(self) weakSelf = self;
    __weak typeof(resolver) weakResolver = resolver;
    [self.activeResolvers addObject:resolver];
    resolver.completion = ^(ASTCProduct *resolvedProduct, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        typeof(resolver) strongResolver = weakResolver;
        if (strongResolver) {
            [strongSelf.activeResolvers removeObject:strongResolver];
        }
        if (completion) {
            completion(resolvedProduct, error);
        }
    };
    [resolver start];
}

- (void)finishProduct:(ASTCProduct *)product completion:(ASTCProductHandler)completion
{
    ASTCFinishProduct(product);
    completion(product, nil);
}

@end

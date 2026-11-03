//
//  ASTCStoreServices.m
//  AppStoreControl
//

#import "ASTCStoreServices.h"
#import "XLog.h"
#import "ASTCPackageInfoReader.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <zlib.h>
#import <Security/Security.h>

static NSString *const ASTCStoreErrorDomain = @"to.define.appstorecontrol.store";

static NSString *ASTCDeviceGUID(void);
static NSString *ASTCBuyParamValue(NSString *buyParams, NSString *field);

static NSError *ASTCError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:ASTCStoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @"Unknown store error"}];
}

#pragma mark - Buy parameters

/// Builds the buy parameter string Apple's commerce endpoint expects.
/// Leaving `externalVersionId` empty asks the store for the version list
/// instead of a single build.
static NSString *ASTCBuildBuyParameters(NSString *adamId,
                                       NSString *pricingParameters,
                                       NSString *externalVersionId,
                                       BOOL installed,
                                       NSNumber *ownerDSID)
{
    NSMutableString *params = [NSMutableString string];
    [params appendString:@"productType=C"];
    [params appendString:@"&price=0"];
    [params appendFormat:@"&salableAdamId=%@", adamId];
    [params appendFormat:@"&pricingParameters=%@", pricingParameters.length ? pricingParameters : @"STDQ"];
    [params appendString:@"&pg=default"];
    // The App Store++ client adds these markers; Apple tolerates unknown
    // parameters and they keep this purchase distinguishable from a real one.
    [params appendString:@"&clientBuyId=1"];
    [params appendFormat:@"&installed=%d", installed ? 1 : 0];
    if (ownerDSID.longLongValue != 0) {
        [params appendFormat:@"&ownerDsid=%@", ownerDSID];
    }
    if (externalVersionId.length > 0) {
        [params appendFormat:@"&appExtVrsId=%@", externalVersionId];
    }
    return params;
}

#pragma mark - Purchase observer

/// Delegate object for SSPurchaseRequest. StoreServices invokes the
/// `SSPurchaseRequestDelegate` selectors on it and hands back the shop
/// response, whose body is the commerce plist we are after.
@interface ASTCPurchaseObserver : NSObject {
    void (^_responseHandler)(NSDictionary *plist, NSError *error);
    BOOL _finished;
}
- (instancetype)initWithResponseHandler:(void (^)(NSDictionary *plist, NSError *error))handler;
@end

@implementation ASTCPurchaseObserver

- (instancetype)initWithResponseHandler:(void (^)(NSDictionary *, NSError *))handler
{
    self = [super init];
    if (self) {
        _responseHandler = [handler copy];
    }
    return self;
}

- (void)finishWithPlist:(NSDictionary *)plist error:(NSError *)error
{
    if (_finished) {
        return;
    }
    _finished = YES;
    void (^handler)(NSDictionary *, NSError *) = _responseHandler;
    _responseHandler = nil;
    XLog(@"Services", @"observer: finishing (plist=%@ error=%@ handler=%@)", plist ? @"yes" : @"nil", error, handler ? @"present" : @"nil");
    if (handler) {
        @try {
            handler(plist, error);
        } @catch (NSException *exception) {
            XLog(@"Services", @"observer: response handler threw %@", exception);
        }
        XLog(@"Services", @"observer: response handler returned");
    }
}

/// Extracts the commerce plist from an SSPurchaseResponse.
- (void)handleResponse:(id)response
{
    NSError *responseError = nil;
    @try {
        responseError = [response valueForKey:@"error"];
    } @catch (__unused NSException *exception) {
    }

    NSData *body = nil;
    @try {
        id urlResponse = [response valueForKey:@"URLResponse"];
        body = [urlResponse valueForKey:@"bodyData"];
    } @catch (__unused NSException *exception) {
    }

    if (![body isKindOfClass:[NSData class]] || body.length == 0) {
        [self finishWithPlist:nil
                        error:responseError ?: ASTCError(1, @"The store returned an empty response.")];
        return;
    }

    NSError *parseError = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:body
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:&parseError];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        [self finishWithPlist:nil
                        error:responseError ?: ASTCError(2, parseError.localizedDescription
                                                             ?: @"The store response could not be parsed.")];
        return;
    }

    NSDictionary *dictionary = (NSDictionary *)plist;
    if (responseError) {
        [self finishWithPlist:dictionary error:responseError];
        return;
    }
    [self finishWithPlist:dictionary error:nil];
}

#pragma mark SSPurchaseRequestDelegate (private selectors)

- (void)purchaseRequest:(id)request purchaseDidSucceedWithResponse:(id)response
{
    XLog(@"Services", @"purchase request succeeded (request=%@)", NSStringFromClass([request class]));
    [self handleResponse:response];
}

- (void)purchaseRequest:(id)request purchaseDidFail:(id)purchase withError:(NSError *)error
{
    XLog(@"Services", @"purchase request failed: %@", error);
    [self finishWithPlist:nil error:error ?: ASTCError(3, @"The store rejected the request.")];
}

#pragma mark SSRequestDelegate

- (void)request:(id)request didFailWithError:(NSError *)error
{
    XLog(@"Services", @"request failed: %@", error);
    [self finishWithPlist:nil error:error ?: ASTCError(4, @"The store request failed.")];
}

- (void)requestDidFinish:(id)request
{
    // Success is delivered through purchaseDidSucceedWithResponse:; if the
    // request finishes without any response the observer has to fail.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self finishWithPlist:nil error:ASTCError(ASTCStoreNoResponseErrorCode, @"The store returned no response.")];
    });
}

@end

#pragma mark - Store services



#pragma mark - Identifier list model

@implementation ASTCIdentifierList
@end

#pragma mark - Plist inspection helpers

/// Compact description of a commerce response for logging.
static NSString *ASTCSummarizeCommerceResponse(NSDictionary *plist, NSError *error)
{
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return [NSString stringWithFormat:@"no plist (error=%@)", error];
    }
    NSDictionary *metadata = nil;
    NSArray *songs = plist[@"songList"];
    if ([songs isKindOfClass:[NSArray class]] && songs.count > 0 && [songs[0] isKindOfClass:[NSDictionary class]]) {
        id value = songs[0][@"metadata"];
        if ([value isKindOfClass:[NSDictionary class]]) {
            metadata = value;
        }
    }
    NSArray *ids = metadata[@"softwareVersionExternalIdentifiers"];
    return [NSString stringWithFormat:@"status=%@ jingle=%@ authorized=%@ short=%@ ext=%@ ids=%lu error=%@",
                                      plist[@"status"],
                                      plist[@"jingleAction"],
                                      plist[@"authorized"],
                                      metadata[@"bundleShortVersionString"],
                                      metadata[@"softwareVersionExternalIdentifier"],
                                      (unsigned long)([ids isKindOfClass:[NSArray class]] ? ids.count : 0),
                                      error];
}

/// Recursively collects key paths whose key matches one of the needles. Used
/// while reverse engineering the commerce response; cheap enough to keep.
static void ASTCCollectMatchingKeys(id object, NSString *prefix, NSArray<NSString *> *needles, NSMutableArray<NSString *> *out, NSUInteger depth)
{
    if (depth > 6 || object == nil) {
        return;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        [object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            NSString *name = [key isKindOfClass:[NSString class]] ? key : [key description];
            NSString *lowercase = name.lowercaseString;
            for (NSString *needle in needles) {
                if ([lowercase containsString:needle]) {
                    NSString *path = prefix.length ? [prefix stringByAppendingFormat:@".%@", name] : name;
                    NSString *summary = [value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]
                        ? [NSString stringWithFormat:@"<%@ %lu>", NSStringFromClass([value class]), (unsigned long)[value count]]
                        : [NSString stringWithFormat:@"<%@>", NSStringFromClass([value class])];
                    [out addObject:[NSString stringWithFormat:@"%@=%@", path, summary]];
                    break;
                }
            }
            NSString *childPrefix = prefix.length ? [prefix stringByAppendingFormat:@".%@", name] : name;
            ASTCCollectMatchingKeys(value, childPrefix, needles, out, depth + 1);
        }];
    } else if ([object isKindOfClass:[NSArray class]]) {
        NSUInteger index = 0;
        for (id value in object) {
            NSString *childPrefix = [prefix stringByAppendingFormat:@"[%lu]", (unsigned long)index];
            ASTCCollectMatchingKeys(value, childPrefix, needles, out, depth + 1);
            index++;
        }
    }
}

#pragma mark - Private interface

@interface ASTCStoreServices (ASTCPrivate)
- (void)runRequestWithBuyParameters:(NSString *)buyParameters
                   createsDownloads:(BOOL)createsDownloads
                          completion:(void (^)(NSDictionary *plist, NSError *error))completion;
- (NSNumber *)activeAccountIdentifier;
- (void)runRequestWithBuyParameters:(NSString *)buyParameters
                   createsDownloads:(BOOL)createsDownloads
                 forceLocalRedownload:(BOOL)forceLocalRedownload
                          completion:(void (^)(NSDictionary *plist, NSError *error))completion;
- (void)nativeCompatibilityBuyForAdamID:(NSString *)adamId
                        externalVersionId:(NSString *)externalVersionId
                            buyParameters:(NSString *)buyParameters
                               completion:(void (^)(NSDictionary *plist, NSError *error))completion;
@end

#pragma mark - Store connection

/// One authenticated store identity, reused across the requests of a lookup
/// so a chooser with many builds does not repeat the preflight and the cookie
/// fetch for each of them.
@interface ASTCStoreIdentity : NSObject
@property (nonatomic, strong) id authenticationContext;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *cookieHeader;
@property (nonatomic, copy) NSString *storefront;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, strong) NSNumber *dsid;
@property (nonatomic, assign) BOOL hasMediaToken;
@property (nonatomic, strong) NSDate *createdAt;
@end

@implementation ASTCStoreIdentity
@end

static const NSTimeInterval kASTCStoreIdentityLifetime = 300.0;
// Native requests per lookup after the list fallback, matching the per-session
// probe cap of the store client.
static const NSUInteger kASTCMaxNativeBuildRequests = 60;
static NSString *const kASTCBuyProductPath = @"/WebObjects/MZBuy.woa/wa/buyProduct";
static NSString *const kASTCVolumeStorePath = @"/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct";
static NSString *const kASTCStoreUserAgent = @"Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6";

static void ASTCSetBool(id target, NSString *selectorName, BOOL value)
{
    SEL selector = NSSelectorFromString(selectorName);
    if ([target respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(target, selector, value);
    }
}

static id ASTCSafeValue(id object, NSString *key)
{
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// Depth-first, case-insensitive search for a key anywhere in a response.
static id ASTCFindResponseValue(id object, NSString *key)
{
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = object;
        for (id candidate in dictionary) {
            if ([candidate isKindOfClass:[NSString class]] && [candidate caseInsensitiveCompare:key] == NSOrderedSame) {
                return dictionary[candidate];
            }
        }
        for (id value in dictionary.allValues) {
            id found = ASTCFindResponseValue(value, key);
            if (found) {
                return found;
            }
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in object) {
            id found = ASTCFindResponseValue(value, key);
            if (found) {
                return found;
            }
        }
    }
    return nil;
}

static NSString *ASTCStringFromValue(id value)
{
    if ([value isKindOfClass:[NSString class]]) {
        return [value length] ? value : nil;
    }
    return [value isKindOfClass:[NSNumber class]] ? [value stringValue] : nil;
}

/// Reads the itunesstored token for the active account: exact account matches
/// win, numeric DSIDs before aliases, and a lone item is used as is.
static NSString *ASTCStoreKeychainToken(id account, NSNumber *dsid)
{
    NSDictionary *query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : @"com.apple.itunesstored.token",
        (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes : @YES,
        (__bridge id)kSecReturnData : @YES,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) {
        XLog(@"Services", @"store identity: keychain token status=%d", (int)status);
        return nil;
    }
    id items = (__bridge_transfer id)result;
    if (![items isKindOfClass:[NSArray class]]) {
        items = [items isKindOfClass:[NSDictionary class]] ? @[items] : @[];
    }

    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    if (dsid) {
        [identifiers addObject:dsid.stringValue];
    }
    id backingAccount = ASTCSafeValue(account, @"backingAccount");
    for (id source in @[account ?: NSNull.null, backingAccount ?: NSNull.null]) {
        for (NSString *key in @[@"uniqueIdentifier", @"altDSID", @"identifier", @"accountIdentifier"]) {
            NSString *value = source == NSNull.null ? nil : ASTCStringFromValue(ASTCSafeValue(source, key));
            if (value) {
                [identifiers addObject:value];
            }
        }
    }

    NSDictionary *best = nil;
    NSInteger bestWeight = 0;
    for (NSDictionary *item in items) {
        NSString *itemAccount = [ASTCStringFromValue(item[(__bridge id)kSecAttrAccount])
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!itemAccount.length || ![identifiers containsObject:itemAccount]) {
            continue;
        }
        BOOL numeric = [itemAccount rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
        BOOL uuid = [[NSUUID alloc] initWithUUIDString:itemAccount] != nil;
        NSInteger weight = numeric ? 300 : (uuid ? 200 : 100);
        if (weight > bestWeight) {
            best = item;
            bestWeight = weight;
        }
    }
    if (!best && [items count] == 1) {
        best = [items firstObject];
    }
    NSData *data = best[(__bridge id)kSecValueData];
    NSString *token = [data isKindOfClass:[NSData class]]
        ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
              stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : nil;
    XLog(@"Services", @"store identity: keychain token items=%lu weight=%ld length=%lu",
           (unsigned long)[items count], (long)bestWeight, (unsigned long)token.length);
    return token.length ? token : nil;
}

static BOOL ASTCHasCachedMediaToken(void)
{
    NSDictionary *query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : @"com.apple.AppleMediaServices.mediaToken",
        (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecReturnAttributes : @YES,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (result) {
        CFRelease(result);
    }
    return status == errSecSuccess;
}

/// Commerce cookies from AppleMediaServices, falling back to the per-account
/// StoreServices cookie store. Blocks for up to 15 seconds.
static NSString *ASTCStoreCookieHeader(id account, NSURL *url)
{
    NSString *cookie = nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    SEL addCookies = NSSelectorFromString(@"ams_addCookiesAsynchronouslyForAccount:clientInfo:bag:cleanupGlobalCookies:");
    SEL result = NSSelectorFromString(@"resultWithTimeout:error:");
    id backingAccount = ASTCSafeValue(account, @"backingAccount");
    if (backingAccount && [request respondsToSelector:addCookies]) {
        @try {
            id promise = ((id (*)(id, SEL, id, id, id, BOOL))objc_msgSend)(request, addCookies, backingAccount, nil, nil, NO);
            if ([promise respondsToSelector:result]) {
                NSError *error = nil;
                ((id (*)(id, SEL, double, NSError **))objc_msgSend)(promise, result, 15.0, &error);
                if (error) {
                    XLog(@"Services", @"store identity: AMS cookies failed: %@", error.localizedDescription);
                }
            }
            cookie = [request valueForHTTPHeaderField:@"Cookie"];
        } @catch (NSException *exception) {
            XLog(@"Services", @"store identity: AMS cookies threw %@", exception.reason);
        }
    }
    NSString *source = @"AMS";
    if (!cookie.length) {
        source = @"SSVCookieStorage";
        @try {
            Class storageClass = NSClassFromString(@"SSVCookieStorage");
            id storage = nil;
            for (NSString *name in @[@"sharedStorage", @"sharedInstance"]) {
                if ([storageClass respondsToSelector:NSSelectorFromString(name)]) {
                    storage = ((id (*)(id, SEL))objc_msgSend)(storageClass, NSSelectorFromString(name));
                    break;
                }
            }
            SEL headers = NSSelectorFromString(@"cookieHeadersForURL:account:");
            if ([storage respondsToSelector:headers]) {
                NSDictionary *fields = ((id (*)(id, SEL, id, id))objc_msgSend)(storage, headers, url, account);
                cookie = [fields isKindOfClass:[NSDictionary class]] ? fields[@"Cookie"] : nil;
            }
        } @catch (NSException *exception) {
            XLog(@"Services", @"store identity: cookie storage threw %@", exception.reason);
        }
    }
    XLog(@"Services", @"store identity: cookie source=%@ length=%lu mediaToken=%d",
           source, (unsigned long)cookie.length, [cookie rangeOfString:@"mz_at0"].location != NSNotFound);
    return cookie.length ? cookie : nil;
}

/// p{N}-buy.itunes.apple.com from the itspod cookie, the account's commerce pod.
static NSString *ASTCCommerceHost(NSString *cookieHeader)
{
    NSRange range = [cookieHeader rangeOfString:@"itspod="];
    if (range.location != NSNotFound) {
        NSScanner *scanner = [NSScanner scannerWithString:[cookieHeader substringFromIndex:NSMaxRange(range)]];
        [scanner scanString:@"p" intoString:NULL];
        int pod = 0;
        if ([scanner scanInt:&pod] && pod > 0) {
            return [NSString stringWithFormat:@"p%d-buy.itunes.apple.com", pod];
        }
    }
    return @"buy.itunes.apple.com";
}

/// Silent daemon authentication. Dialogs stay suppressed: a lookup never
/// prompts, it reports that authorization is required instead.
static id ASTCStoreAuthenticationContext(id account, NSNumber *dsid, NSString *token)
{
    Class contextClass = NSClassFromString(@"SSAuthenticationContext");
    if (!contextClass || !account) {
        return nil;
    }
    id base = ((id (*)(id, SEL, id))objc_msgSend)([contextClass alloc], NSSelectorFromString(@"initWithAccount:"), account);
    id context = [base mutableCopy];
    ASTCSetBool(context, @"setAllowsSilentAuthentication:", YES);
    ASTCSetBool(context, @"setShouldSuppressDialogs:", YES);
    ASTCSetBool(context, @"setForceDaemonAuthentication:", YES);
    ASTCSetBool(context, @"setAllowsRetry:", NO);
    ASTCSetBool(context, @"setShouldCreateNewSession:", NO);
    SEL setIdentifier = NSSelectorFromString(@"setRequiredUniqueIdentifier:");
    if (dsid && [context respondsToSelector:setIdentifier]) {
        ((void (*)(id, SEL, id))objc_msgSend)(context, setIdentifier, dsid);
    }
    SEL setToken = NSSelectorFromString(@"setPasswordEquivalentToken:");
    if (token.length && [context respondsToSelector:setToken]) {
        ((void (*)(id, SEL, id))objc_msgSend)(context, setToken, token);
    }
    return context;
}

/// Maps a response without the requested data to an error. Authorization
/// dialogs are reported and never followed: following one starts a purchase.
static NSError *ASTCStoreFailure(NSDictionary *plist, NSInteger status, NSError *error)
{
    NSString *failureType = ASTCStringFromValue(ASTCFindResponseValue(plist, @"failureType"));
    NSString *message = ASTCStringFromValue(ASTCFindResponseValue(plist, @"customerMessage"));
    id dialog = ASTCFindResponseValue(plist, @"dialog");
    NSString *dialogKind = [dialog isKindOfClass:[NSDictionary class]] ? ASTCStringFromValue(dialog[@"kind"]) : nil;
    if ([failureType isEqualToString:@"2071"] || [failureType isEqualToString:@"2077"]
        || [message containsString:@"BadPasswordToken"]
        || (dialogKind && [dialogKind caseInsensitiveCompare:@"authorization"] == NSOrderedSame)) {
        XLog(@"Services", @"store lookup stopped: authorization required (failureType=%@ dialog=%@)", failureType, dialogKind);
        return ASTCError(ASTCStoreLookupStoppedErrorCode, @"Apple ID authorization is required. Version lookup stopped.");
    }
    if (message.length) {
        return ASTCError(11, message);
    }
    if (error) {
        return error;
    }
    if (failureType.length) {
        return ASTCError(11, [NSString stringWithFormat:@"The App Store refused the request (%@).", failureType]);
    }
    if (status < 200 || status >= 300) {
        return ASTCError(10, [NSString stringWithFormat:@"The App Store returned HTTP %ld.", (long)status]);
    }
    return ASTCError(10, @"The App Store returned no version data.");
}

static NSString *ASTCRedactedText(id value)
{
    NSString *text = ASTCStringFromValue(value);
    if (!text) {
        return @"-";
    }
    return [text stringByReplacingOccurrencesOfString:@"\\S+@\\S+"
                                           withString:@"<email>"
                                              options:NSRegularExpressionSearch
                                                range:NSMakeRange(0, text.length)];
}

/// Logs what an authorization response asks for. Buy parameters can carry
/// identity values, so only their field names and pricing fields are written.
static void ASTCLogStoreDialog(NSDictionary *plist)
{
    id dialog = ASTCFindResponseValue(plist, @"dialog");
    NSDictionary *dictionary = [dialog isKindOfClass:[NSDictionary class]] ? dialog : nil;
    id action = dictionary[@"okButtonAction"];
    NSDictionary *okAction = [action isKindOfClass:[NSDictionary class]] ? action : nil;
    NSString *buyParameters = ASTCStringFromValue(okAction[@"buyParams"]);
    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    for (NSString *pair in [buyParameters componentsSeparatedByString:@"&"]) {
        [fields addObject:[pair componentsSeparatedByString:@"="].firstObject];
    }
    XLog(@"Services", @"store dialog: failureType=%@ customerMessage=%@ kind=%@ message=%@ explanation=%@ okKind=%@ fields=%@ price=%@ pricing=%@",
           ASTCRedactedText(ASTCFindResponseValue(plist, @"failureType")),
           ASTCRedactedText(ASTCFindResponseValue(plist, @"customerMessage")),
           ASTCRedactedText(dictionary[@"kind"]),
           ASTCRedactedText(dictionary[@"message"]),
           ASTCRedactedText(dictionary[@"explanation"]),
           ASTCRedactedText(okAction[@"kind"]),
           [fields componentsJoinedByString:@","],
           ASTCBuyParamValue(buyParameters, @"price") ?: @"-",
           ASTCBuyParamValue(buyParameters, @"pricingParameters") ?: @"-");
}

/// Returns the dialog's buy parameters only when following them can do nothing
/// but authorize a free redownload of this exact app.
static NSString *ASTCFollowableBuyParameters(NSDictionary *plist, NSString *adamId)
{
    id dialog = ASTCFindResponseValue(plist, @"dialog");
    id action = [dialog isKindOfClass:[NSDictionary class]] ? dialog[@"okButtonAction"] : nil;
    NSDictionary *okAction = [action isKindOfClass:[NSDictionary class]] ? action : nil;
    NSString *kind = ASTCStringFromValue(okAction[@"kind"]);
    NSString *buyParameters = ASTCStringFromValue(okAction[@"buyParams"]);
    NSString *reason = nil;
    if (!kind || [kind caseInsensitiveCompare:@"Buy"] != NSOrderedSame) {
        reason = @"no Buy action";
    } else if (!buyParameters) {
        reason = @"no buy parameters";
    } else if (ASTCBuyParamValue(buyParameters, @"price").length == 0 || ASTCBuyParamValue(buyParameters, @"price").doubleValue != 0.0) {
        reason = @"not free";
    } else if (![ASTCBuyParamValue(buyParameters, @"pricingParameters") isEqualToString:@"STDRDL"]) {
        reason = @"not a redownload";
    } else if (![ASTCBuyParamValue(buyParameters, @"salableAdamId") isEqualToString:adamId]) {
        reason = @"different app";
    }
    if (reason) {
        XLog(@"Services", @"store fallback refused: %@", reason);
        return nil;
    }
    return buyParameters;
}

/// The buy parameters with `appExtVrsId` pointing at one build.
static NSString *ASTCBuyParametersSelectingBuild(NSString *buyParameters, NSString *externalID)
{
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (NSString *pair in [buyParameters componentsSeparatedByString:@"&"]) {
        if (![pair hasPrefix:@"appExtVrsId="]) {
            [pairs addObject:pair];
        }
    }
    [pairs addObject:[@"appExtVrsId=" stringByAppendingString:externalID]];
    return [pairs componentsJoinedByString:@"&"];
}

static ASTCIdentifierList *ASTCIdentifierListFromPlist(NSDictionary *plist)
{
    id rawIdentifiers = ASTCFindResponseValue(plist, @"softwareVersionExternalIdentifiers");
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    if ([rawIdentifiers isKindOfClass:[NSArray class]]) {
        for (id value in rawIdentifiers) {
            NSString *identifier = ASTCStringFromValue(value);
            if (identifier) {
                [identifiers addObject:identifier];
            }
        }
    }
    if (identifiers.count == 0) {
        return nil;
    }

    ASTCIdentifierList *list = [ASTCIdentifierList new];
    list.identifiers = identifiers.array;
    list.displayVersionsByExternalId = [NSMutableDictionary dictionary];
    NSArray *songs = plist[@"songList"];
    NSDictionary *song = [songs isKindOfClass:[NSArray class]] && [songs.firstObject isKindOfClass:[NSDictionary class]]
        ? songs.firstObject : nil;
    void (^collectDeltas)(id) = ^(id deltas) {
        if (![deltas isKindOfClass:[NSArray class]]) {
            return;
        }
        for (id delta in deltas) {
            if (![delta isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *externalId = ASTCStringFromValue(delta[@"priorVersionExternalIdentifier"]);
            NSString *shortVersion = ASTCStringFromValue(delta[@"priorVersionBundleShortVersionString"]);
            if (externalId && shortVersion) {
                list.displayVersionsByExternalId[externalId] = shortVersion;
            }
        }
    };
    collectDeltas(song[@"deltaPackages"]);
    collectDeltas(ASTCFindResponseValue(song[@"thinned-app"], @"deltaPackages"));
    list.latestDisplayVersion = ASTCStringFromValue(ASTCFindResponseValue(plist, @"bundleShortVersionString"));
    list.latestExternalVersionId = ASTCStringFromValue(ASTCFindResponseValue(plist, @"softwareVersionExternalIdentifier"));
    list.minimumOSVersion = ASTCStringFromValue(ASTCFindResponseValue(plist, @"minimumOSVersion"));
    return list;
}

@implementation ASTCStoreServices {
    dispatch_queue_t _workQueue;
    NSMutableDictionary<NSString *, NSDictionary *> *_resolutionCache;
    NSMutableSet *_activeRequests;
    ASTCStoreIdentity *_storeIdentity;
    NSMutableDictionary<NSString *, NSString *> *_buyContinuations;
    NSMutableDictionary<NSString *, NSNumber *> *_nativeBuildRequestCounts;
}

+ (instancetype)sharedInstance
{
    static ASTCStoreServices *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ASTCStoreServices alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("to.define.appstorecontrol.store", DISPATCH_QUEUE_SERIAL);
        _resolutionCache = [NSMutableDictionary dictionary];
        _activeRequests = [NSMutableSet set];
        _buyContinuations = [NSMutableDictionary dictionary];
        _nativeBuildRequestCounts = [NSMutableDictionary dictionary];
    }
    return self;
}

+ (BOOL)isAvailable
{
    return NSClassFromString(@"SSURLConnectionRequest") != Nil && NSClassFromString(@"SSPurchaseRequest") != Nil;
}

- (NSNumber *)activeAccountIdentifier
{
    @try {
        Class storeClass = NSClassFromString(@"SSAccountStore");
        if (!storeClass) {
            return nil;
        }
        id store = ((id (*)(id, SEL))objc_msgSend)(storeClass, NSSelectorFromString(@"defaultStore"));
        id account = [store valueForKey:@"activeAccount"];
        NSNumber *identifier = [account valueForKey:@"uniqueIdentifier"];
        if ([identifier isKindOfClass:[NSNumber class]] && identifier.longLongValue != 0) {
            return identifier;
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

/// Runs one purchase-shaped request and hands the commerce plist to the
/// response handler. `createsDownloads` decides whether appstored turns the
/// request into a real download/install.
- (void)runRequestWithBuyParameters:(NSString *)buyParameters
                   createsDownloads:(BOOL)createsDownloads
                          completion:(void (^)(NSDictionary *plist, NSError *error))completion
{
    [self runRequestWithBuyParameters:buyParameters
                     createsDownloads:createsDownloads
                   forceLocalRedownload:NO
                           completion:completion];
}

- (void)runRequestWithBuyParameters:(NSString *)buyParameters
                   createsDownloads:(BOOL)createsDownloads
                 forceLocalRedownload:(BOOL)forceLocalRedownload
                          completion:(void (^)(NSDictionary *plist, NSError *error))completion
{
    Class purchaseClass = NSClassFromString(@"SSPurchase");
    Class requestClass = NSClassFromString(@"SSPurchaseRequest");
    if (!purchaseClass || !requestClass) {
        if (completion) {
            completion(nil, ASTCError(6, @"The Store framework is not available in this process."));
        }
        return;
    }

    id purchase = ((id (*)(id, SEL, id))objc_msgSend)(purchaseClass,
                                                       NSSelectorFromString(@"purchaseWithBuyParameters:"),
                                                       buyParameters);
    if (!purchase) {
        if (completion) {
            completion(nil, ASTCError(7, @"The store rejected the buy parameters."));
        }
        return;
    }

    NSNumber *accountIdentifier = [self activeAccountIdentifier];
    if (accountIdentifier) {
        @try {
            [purchase setValue:accountIdentifier forKey:@"accountIdentifier"];
        } @catch (__unused NSException *exception) {
        }
        @try {
            [purchase setValue:accountIdentifier forKey:@"ownerAccountDSID"];
        } @catch (__unused NSException *exception) {
        }
    }
    @try {
        [purchase setValue:@(forceLocalRedownload) forKey:@"usesLocalRedownloadParametersIfPossible"];
    } @catch (__unused NSException *exception) {
    }

    // Probe requests must not create downloads; install requests must.
    @try { [purchase setValue:@(createsDownloads) forKey:@"createsDownloads"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@(createsDownloads) forKey:@"createsJobs"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@(createsDownloads) forKey:@"createsInstallJobs"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@NO forKey:@"backgroundPurchase"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@YES forKey:@"preauthenticated"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@YES forKey:@"skipSoftwareAccountPreflight"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@(createsDownloads) forKey:@"displaysOnLockScreen"]; } @catch (__unused NSException *e) {}

    XLog(@"Services", @"purchase flags read-back: downloads=%@ jobs=%@ installJobs=%@ ownerDSID=%@ localRedownload=%@",
           [purchase valueForKey:@"createsDownloads"],
           [purchase valueForKey:@"createsJobs"],
           [purchase valueForKey:@"createsInstallJobs"],
           [purchase valueForKey:@"ownerAccountDSID"],
           [purchase valueForKey:@"usesLocalRedownloadParametersIfPossible"]);

    id request = ((id (*)(id, SEL, id))objc_msgSend)([requestClass alloc],
                                                      NSSelectorFromString(@"initWithPurchases:"),
                                                      @[purchase]);
    if (!request) {
        if (completion) {
            completion(nil, ASTCError(8, @"The store request could not be created."));
        }
        return;
    }

    @try { [request setValue:@NO forKey:@"needsAuthentication"]; } @catch (__unused NSException *e) {}
    @try { [request setValue:@YES forKey:@"backgroundRequest"]; } @catch (__unused NSException *e) {}
    // The request's values overwrite the purchase's when it is sent, and they
    // default to YES.
    @try { [request setValue:@(createsDownloads) forKey:@"createsDownloads"]; } @catch (__unused NSException *e) {}
    @try { [request setValue:@(createsDownloads) forKey:@"createsJobs"]; } @catch (__unused NSException *e) {}

    ASTCPurchaseObserver *observer = [[ASTCPurchaseObserver alloc] initWithResponseHandler:completion];
    @try {
        [request setValue:observer forKey:@"delegate"];
    } @catch (__unused NSException *exception) {
        if (completion) {
            completion(nil, ASTCError(9, @"The store request delegate could not be set."));
        }
        return;
    }

    // Keep the observer alive until the request finishes: StoreServices only
    // holds a weak delegate reference.
    objc_setAssociatedObject(request, "to.define.appstorecontrol.observer", observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    XLog(@"Services", @"starting store request buyParams=%@ creates=%d account=%@", buyParameters, createsDownloads, accountIdentifier);

    dispatch_async(_workQueue, ^{
        ((void (*)(id, SEL))objc_msgSend)(request, NSSelectorFromString(@"start"));
    });

    // Hard timeout: a silent store must not leave the UI spinning forever.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (observer) {
            [observer requestDidFinish:request];
        }
    });
}

- (void)prepareStoreIdentityWithCompletion:(void (^)(ASTCStoreIdentity *identity, NSError *error))completion
{
    @synchronized(self) {
        if (_storeIdentity && -_storeIdentity.createdAt.timeIntervalSinceNow < kASTCStoreIdentityLifetime) {
            completion(_storeIdentity, nil);
            return;
        }
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id account = nil;
        @try {
            id store = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"SSAccountStore"), NSSelectorFromString(@"defaultStore"));
            account = [store valueForKey:@"activeAccount"];
        } @catch (__unused NSException *exception) {
        }
        NSNumber *dsid = [self activeAccountIdentifier];
        if (!account || !dsid) {
            completion(nil, ASTCError(ASTCStoreLookupStoppedErrorCode, @"Sign in to the App Store to look up versions."));
            return;
        }

        NSString *token = ASTCStoreKeychainToken(account, dsid);
        NSURL *cookieURL = [NSURL URLWithString:@"https://buy.itunes.apple.com/"];
        NSString *cookieHeader = ASTCStoreCookieHeader(account, cookieURL);
        NSString *storefront = ASTCStringFromValue(ASTCSafeValue(account, @"storeFrontIdentifier"));

        __block BOOL finished = NO;
        __block id heldRequest = nil;
        void (^finish)(id) = ^(id sessionAccount) {
            @synchronized(self) {
                if (finished) {
                    return;
                }
                finished = YES;
                if (heldRequest) {
                    [self->_activeRequests removeObject:heldRequest];
                    heldRequest = nil;
                }
            }
            ASTCStoreIdentity *identity = [ASTCStoreIdentity new];
            identity.authenticationContext = ASTCStoreAuthenticationContext(sessionAccount ?: account, dsid, token);
            identity.token = token;
            identity.cookieHeader = cookieHeader;
            identity.storefront = storefront;
            identity.host = ASTCCommerceHost(cookieHeader);
            identity.dsid = dsid;
            identity.hasMediaToken = ASTCHasCachedMediaToken();
            identity.createdAt = [NSDate date];
            @synchronized(self) {
                self->_storeIdentity = identity;
            }
            XLog(@"Services", @"store identity ready: host=%@ token=%d cookie=%d storefront=%d mediaToken=%d session=%d",
                   identity.host, token.length > 0, cookieHeader.length > 0, storefront.length > 0,
                   identity.hasMediaToken, sessionAccount != nil);
            completion(identity, nil);
        };

        Class requestClass = NSClassFromString(@"SSAuthenticateRequest");
        SEL start = NSSelectorFromString(@"startWithAuthenticateResponseBlock:");
        id context = ASTCStoreAuthenticationContext(account, dsid, nil);
        id request = requestClass && context
            ? ((id (*)(id, SEL, id))objc_msgSend)([requestClass alloc], NSSelectorFromString(@"initWithAuthenticationContext:"), context)
            : nil;
        if (![request respondsToSelector:start]) {
            XLog(@"Services", @"store identity: authentication preflight unavailable");
            finish(nil);
            return;
        }
        @synchronized(self) {
            heldRequest = request;
            [self->_activeRequests addObject:request];
        }
        void (^response)(id) = ^(id authenticateResponse) {
            id sessionAccount = nil;
            for (NSString *key in @[@"authenticatedAccount", @"account"]) {
                sessionAccount = ASTCSafeValue(authenticateResponse, key);
                if (sessionAccount) {
                    break;
                }
            }
            XLog(@"Services", @"store identity: preflight error=%@ session=%d",
                   ASTCSafeValue(authenticateResponse, @"error") ?: @"-", sessionAccount != nil);
            finish(sessionAccount);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            finish(nil);
        });
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(request, start, response);
        } @catch (NSException *exception) {
            XLog(@"Services", @"store identity: preflight threw %@", exception.reason);
            finish(nil);
        }
    });
}

/// Sends one store request through itunesstored. This is plain HTTP in the
/// daemon: no SSPurchase, so nothing reaches the purchase or download queues.
- (void)sendStoreRequestWithIdentity:(ASTCStoreIdentity *)identity
                                path:(NSString *)path
                                body:(NSData *)body
                         contentType:(NSString *)contentType
                          mescalSign:(BOOL)mescalSign
                          completion:(void (^)(NSDictionary *plist, NSInteger status, NSError *error))completion
{
    Class propertiesClass = NSClassFromString(@"SSMutableURLRequestProperties");
    Class requestClass = NSClassFromString(@"SSURLConnectionRequest");
    if (!propertiesClass || !requestClass) {
        completion(nil, 0, ASTCError(13, @"SSURLConnectionRequest is unavailable."));
        return;
    }

    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"https";
    components.host = identity.host;
    components.path = path;
    NSString *guid = ASTCDeviceGUID();
    if (guid.length) {
        components.queryItems = @[[NSURLQueryItem queryItemWithName:@"guid" value:guid]];
    }

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    headers[@"Content-Type"] = contentType;
    headers[@"iCloud-DSID"] = identity.dsid.stringValue;
    headers[@"X-Dsid"] = identity.dsid.stringValue;
    headers[@"User-Agent"] = kASTCStoreUserAgent;
    if (identity.cookieHeader.length) {
        headers[@"Cookie"] = identity.cookieHeader;
    }
    if (identity.token.length) {
        headers[@"X-Token"] = identity.token;
    }
    if (identity.storefront.length) {
        headers[@"X-Apple-Store-Front"] = identity.storefront;
    }

    id properties = [propertiesClass new];
    id request = nil;
    @try {
        [properties setValue:components.URL forKey:@"URL"];
        [properties setValue:@"POST" forKey:@"HTTPMethod"];
        [properties setValue:body forKey:@"HTTPBody"];
        [properties setValue:headers forKey:@"HTTPHeaders"];
        [properties setValue:@YES forKey:@"ITunesStoreRequest"];
        [properties setValue:@(identity.token.length > 0) forKey:@"shouldSendSecureToken"];
        [properties setValue:@YES forKey:@"shouldSetCookies"];
        [properties setValue:@YES forKey:@"shouldProcessProtocol"];
        ASTCSetBool(properties, @"setShouldAddKBSyncData:", YES);
        SEL setKBSyncType = NSSelectorFromString(@"setKBSyncType:");
        if ([properties respondsToSelector:setKBSyncType]) {
            ((void (*)(id, SEL, long long))objc_msgSend)(properties, setKBSyncType, 1);
        }
        [properties setValue:@YES forKey:@"requiresHTTPS"];
        [properties setValue:@YES forKey:@"shouldDecodeResponse"];

        request = ((id (*)(id, SEL, id))objc_msgSend)([requestClass alloc], NSSelectorFromString(@"initWithRequestProperties:"), properties);
        if (identity.authenticationContext) {
            [request setValue:identity.authenticationContext forKey:@"authenticationContext"];
        }
        ASTCSetBool(request, @"setShouldMescalSign:", mescalSign);
        SEL setRetryCount = NSSelectorFromString(@"setAuthenticationRetryCount:");
        if ([request respondsToSelector:setRetryCount]) {
            ((void (*)(id, SEL, long long))objc_msgSend)(request, setRetryCount, 0);
        }
        ASTCSetBool(request, @"setRunsInProcess:", NO);
        ASTCSetBool(request, @"setSendsResponseForHTTPFailures:", YES);
    } @catch (NSException *exception) {
        completion(nil, 0, ASTCError(14, exception.reason));
        return;
    }

    __block BOOL finished = NO;
    void (^finish)(NSDictionary *, NSInteger, NSError *) = ^(NSDictionary *plist, NSInteger status, NSError *error) {
        @synchronized(self) {
            if (finished) {
                return;
            }
            finished = YES;
            [self->_activeRequests removeObject:request];
        }
        completion(plist, status, error);
    };
    @synchronized(self) {
        [_activeRequests addObject:request];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        finish(nil, 0, ASTCError(5, @"The App Store did not respond."));
    });

    XLog(@"Services", @"store request: POST %@ %@ bytes=%lu mescal=%d", identity.host, path, (unsigned long)body.length, mescalSign);
    void (^handler)(id, NSError *) = ^(id response, NSError *error) {
        NSInteger status = [ASTCSafeValue(response, @"statusCode") integerValue];
        NSData *bodyData = ASTCSafeValue(response, @"bodyData");
        id plist = [bodyData isKindOfClass:[NSData class]] && bodyData.length
            ? [NSPropertyListSerialization propertyListWithData:bodyData options:0 format:NULL error:NULL]
            : nil;
        NSDictionary *dictionary = [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
        XLog(@"Services", @"store response: HTTP %ld bytes=%lu error=%@ %@", (long)status,
               (unsigned long)([bodyData isKindOfClass:[NSData class]] ? bodyData.length : 0),
               error.localizedDescription ?: @"-", ASTCSummarizeCommerceResponse(dictionary, error));
        finish(dictionary, status, error);
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(request, NSSelectorFromString(@"startWithConnectionResponseBlock:"), handler);
    } @catch (NSException *exception) {
        finish(nil, 0, ASTCError(14, exception.reason));
    }
}

- (void)fetchVersionIdentifiersForAdamID:(NSString *)adamId completion:(ASTCIdentifiersHandler)completion
{
    [self prepareStoreIdentityWithCompletion:^(ASTCStoreIdentity *identity, NSError *identityError) {
        if (!identity) {
            completion(nil, identityError);
            return;
        }
        NSString *form = [NSString stringWithFormat:
            @"productType=C&price=0&salableAdamId=%@&pricingParameters=STDRDL&clientBuyId=1&installed=0", adamId];
        [self sendStoreRequestWithIdentity:identity
                                      path:kASTCBuyProductPath
                                      body:[form dataUsingEncoding:NSUTF8StringEncoding]
                               contentType:@"application/x-www-form-urlencoded"
                                mescalSign:identity.hasMediaToken
                                completion:^(NSDictionary *plist, NSInteger status, NSError *error) {
            ASTCIdentifierList *list = status >= 200 && status < 300 ? ASTCIdentifierListFromPlist(plist) : nil;
            if (list) {
                XLog(@"Services", @"identifier list for %@: %lu identifiers, latest=%@", adamId,
                       (unsigned long)list.identifiers.count, list.latestExternalVersionId);
                @synchronized(self) {
                    [self->_buyContinuations removeObjectForKey:adamId];
                }
                completion(list, nil);
                return;
            }
            ASTCLogStoreDialog(plist);
            NSError *failure = ASTCStoreFailure(plist, status, error);
            NSString *continuation = ASTCFollowableBuyParameters(plist, adamId);
            if (!continuation) {
                completion(nil, failure);
                return;
            }
            XLog(@"Services", @"store fallback: following the Buy action once for %@", adamId);
            [self nativeCompatibilityBuyForAdamID:adamId
                                externalVersionId:ASTCBuyParamValue(continuation, @"appExtVrsId")
                                    buyParameters:continuation
                                       completion:^(NSDictionary *nativePlist, NSError *nativeError) {
                // The authorization may have refreshed the session.
                @synchronized(self) {
                    self->_storeIdentity = nil;
                }
                ASTCIdentifierList *nativeList = ASTCIdentifierListFromPlist(nativePlist);
                if (!nativeList) {
                    ASTCLogStoreDialog(nativePlist);
                    completion(nil, ASTCStoreFailure(nativePlist, 200, nativeError));
                    return;
                }
                XLog(@"Services", @"store fallback: identifier list for %@: %lu identifiers", adamId, (unsigned long)nativeList.identifiers.count);
                @synchronized(self) {
                    self->_buyContinuations[adamId] = continuation;
                    self->_nativeBuildRequestCounts[adamId] = @0;
                }
                completion(nativeList, nil);
            }];
        }];
    }];
}

/// Asks for one build. After a list fallback the store only answers native
/// requests, so those are used, capped by kASTCMaxNativeBuildRequests. Otherwise
/// buyProduct is what a working session was observed to send; the static flow of
/// the original client uses volumeStoreDownloadProduct, so that shape is tried
/// when buyProduct answers without build data.
- (void)fetchBuildPlistForAdamID:(NSString *)adamId
                      externalID:(NSString *)externalID
                        identity:(ASTCStoreIdentity *)identity
                      completion:(void (^)(NSDictionary *song, NSError *error))completion
{
    NSDictionary *(^buildSong)(NSDictionary *) = ^NSDictionary *(NSDictionary *plist) {
        id songs = ASTCFindResponseValue(plist, @"songList");
        id song = [songs isKindOfClass:[NSArray class]] ? [songs firstObject] : nil;
        if (![song isKindOfClass:[NSDictionary class]]) {
            return nil;
        }
        return ASTCFindResponseValue(song, @"metadata") || ASTCFindResponseValue(song, @"URL") ? song : nil;
    };

    NSString *continuation = nil;
    BOOL allowed = NO;
    @synchronized(self) {
        continuation = _buyContinuations[adamId];
        NSUInteger count = _nativeBuildRequestCounts[adamId].unsignedIntegerValue;
        allowed = count < kASTCMaxNativeBuildRequests;
        if (continuation && allowed) {
            _nativeBuildRequestCounts[adamId] = @(count + 1);
        }
    }
    if (continuation) {
        if (!allowed) {
            XLog(@"Services", @"store fallback: native build request limit reached for %@", adamId);
            completion(nil, ASTCError(ASTCStoreLookupStoppedErrorCode, @"Version lookup stopped at the native request limit."));
            return;
        }
        [self nativeCompatibilityBuyForAdamID:adamId
                            externalVersionId:externalID
                                buyParameters:ASTCBuyParametersSelectingBuild(continuation, externalID)
                                   completion:^(NSDictionary *plist, NSError *error) {
            NSDictionary *song = buildSong(plist);
            if (!song) {
                ASTCLogStoreDialog(plist);
            }
            completion(song, song ? nil : ASTCStoreFailure(plist, 200, error));
        }];
        return;
    }

    NSString *form = [NSString stringWithFormat:
        @"productType=C&price=0&salableAdamId=%@&pricingParameters=STDRDL&clientBuyId=1&installed=0&appExtVrsId=%@",
        adamId, externalID];
    [self sendStoreRequestWithIdentity:identity
                                  path:kASTCBuyProductPath
                                  body:[form dataUsingEncoding:NSUTF8StringEncoding]
                           contentType:@"application/x-www-form-urlencoded"
                            mescalSign:YES
                            completion:^(NSDictionary *plist, NSInteger status, NSError *error) {
        NSDictionary *song = status >= 200 && status < 300 ? buildSong(plist) : nil;
        if (song) {
            completion(song, nil);
            return;
        }
        NSError *failure = ASTCStoreFailure(plist, status, error);
        if ([failure.domain isEqualToString:ASTCStoreErrorDomain] && failure.code == ASTCStoreLookupStoppedErrorCode) {
            completion(nil, failure);
            return;
        }

        NSDictionary *parameters = @{
            @"creditDisplay" : @"",
            @"guid" : ASTCDeviceGUID() ?: @"",
            @"salableAdamId" : @(adamId.longLongValue),
            @"externalVersionId" : externalID,
        };
        NSData *body = [NSPropertyListSerialization dataWithPropertyList:parameters
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:NULL];
        [self sendStoreRequestWithIdentity:identity
                                      path:kASTCVolumeStorePath
                                      body:body
                               contentType:@"application/x-apple-plist"
                                mescalSign:YES
                                completion:^(NSDictionary *fallbackPlist, NSInteger fallbackStatus, NSError *fallbackError) {
            NSDictionary *fallbackSong = fallbackStatus >= 200 && fallbackStatus < 300 ? buildSong(fallbackPlist) : nil;
            completion(fallbackSong, fallbackSong ? nil : ASTCStoreFailure(fallbackPlist, fallbackStatus, fallbackError));
        }];
    }];
}

- (void)resolveVersionForAdamID:(NSString *)adamId
                     externalID:(NSString *)externalID
              pricingParameters:(NSString *)pricingParameters
                     completion:(ASTCVersionHandler)completion
{
    NSString *cacheKey = [NSString stringWithFormat:@"%@-%@", adamId, externalID];
    NSDictionary *cached = nil;
    @synchronized(self) {
        cached = _resolutionCache[cacheKey];
    }
    if (cached) {
        ASTCVersion *version = [ASTCVersion new];
        version.externalVersionId = externalID;
        version.displayVersion = cached[@"displayVersion"];
        version.minimumOSVersion = cached[@"minimumOSVersion"];
        version.bundleVersion = cached[@"bundleVersion"];
        if (completion) {
            completion(version, nil);
        }
        return;
    }

    // The install path keeps using these buy parameters.
    NSString *buyParameters = ASTCBuildBuyParameters(adamId, pricingParameters, externalID, NO, [self activeAccountIdentifier]);
    void (^finish)(NSString *, NSString *, NSString *, NSURL *) = ^(NSString *displayVersion, NSString *minimumOS, NSString *bundleVersion, NSURL *packageURL) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"displayVersion"] = displayVersion;
        if (minimumOS.length) {
            entry[@"minimumOSVersion"] = minimumOS;
        }
        if (bundleVersion.length) {
            entry[@"bundleVersion"] = bundleVersion;
        }
        @synchronized(self) {
            self->_resolutionCache[cacheKey] = entry;
        }
        ASTCVersion *version = [ASTCVersion new];
        version.externalVersionId = externalID;
        version.displayVersion = displayVersion;
        version.minimumOSVersion = minimumOS;
        version.bundleVersion = bundleVersion;
        version.buyParams = buyParameters;
        version.packageURL = packageURL;
        XLog(@"Services", @"resolved ext=%@ -> %@ (minOS=%@ build=%@ packageURL=%@)", externalID, displayVersion,
               minimumOS ?: @"-", bundleVersion ?: @"-", packageURL ? @"yes" : @"no");
        if (completion) {
            completion(version, nil);
        }
    };

    [self prepareStoreIdentityWithCompletion:^(ASTCStoreIdentity *identity, NSError *identityError) {
        if (!identity) {
            if (completion) {
                completion(nil, identityError);
            }
            return;
        }
        [self fetchBuildPlistForAdamID:adamId externalID:externalID identity:identity completion:^(NSDictionary *song, NSError *error) {
            if (!song) {
                XLog(@"Services", @"resolve failed for ext=%@: %@", externalID, error.localizedDescription);
                if (completion) {
                    completion(nil, error);
                }
                return;
            }
            NSString *returnedIdentifier = ASTCStringFromValue(ASTCFindResponseValue(song, @"softwareVersionExternalIdentifier"))
                ?: ASTCStringFromValue(ASTCFindResponseValue(song, @"versionExternalIdentifier"))
                ?: ASTCStringFromValue(ASTCFindResponseValue(song, @"externalVersionId"));
            if (returnedIdentifier && ![returnedIdentifier isEqualToString:externalID]) {
                XLog(@"Services", @"resolve ext=%@: Apple substituted %@", externalID, returnedIdentifier);
                if (completion) {
                    completion(nil, ASTCError(16, @"Apple substituted a different build."));
                }
                return;
            }

            NSString *packageURLString = nil;
            for (NSString *key in @[@"URL", @"url", @"downloadURL", @"assetURL"]) {
                packageURLString = ASTCStringFromValue(song[key]);
                if (packageURLString) {
                    break;
                }
            }
            NSURL *packageURL = packageURLString ? [NSURL URLWithString:packageURLString] : nil;
            NSDictionary *metadata = [song[@"metadata"] isKindOfClass:[NSDictionary class]] ? song[@"metadata"] : song;
            NSString *displayVersion = ASTCStringFromValue(metadata[@"bundleShortVersionString"]);
            NSString *minimumOS = ASTCStringFromValue(metadata[@"minimumOSVersion"]);
            NSString *bundleVersion = ASTCStringFromValue(metadata[@"bundleVersion"]);
            if (displayVersion) {
                finish(displayVersion, minimumOS, bundleVersion, packageURL);
                return;
            }
            if (!packageURL) {
                if (completion) {
                    completion(nil, ASTCError(11, @"Apple did not return metadata for this build."));
                }
                return;
            }
            [[ASTCPackageInfoReader sharedInstance] readInfoPlistAtURL:packageURL completion:^(NSDictionary *info, NSError *readError) {
                NSString *packageVersion = ASTCStringFromValue(info[@"CFBundleShortVersionString"]);
                if (!packageVersion) {
                    if (completion) {
                        completion(nil, readError ?: ASTCError(10, @"The package has no version number."));
                    }
                    return;
                }
                finish(packageVersion, ASTCStringFromValue(info[@"MinimumOSVersion"]),
                       ASTCStringFromValue(info[@"CFBundleVersion"]), packageURL);
            }];
        }];
    }];
}


static NSString *ASTCDeviceGUID(void)
{
    @try {
        Class lockdownClass = NSClassFromString(@"SSLockdown");
        id lockdown = nil;
        for (NSString *name in @[@"sharedInstance", @"defaultLockdown", @"sharedLockdown"]) {
            if ([lockdownClass respondsToSelector:NSSelectorFromString(name)]) {
                lockdown = ((id (*)(id, SEL))objc_msgSend)(lockdownClass, NSSelectorFromString(name));
                break;
            }
        }
        if (!lockdown) {
            lockdown = [lockdownClass new];
        }
        if ([lockdown respondsToSelector:NSSelectorFromString(@"copyDeviceGUID")]) {
            return ((id (*)(id, SEL))objc_msgSend)(lockdown, NSSelectorFromString(@"copyDeviceGUID"));
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

#pragma mark - Native StoreKitUI compatibility Buy (faithful 2.3.15 authorization)

/// Scans a form-urlencoded buy-parameter string for the numeric value of a
/// field (e.g. `price`). Returns nil when the field is absent.
static NSString *ASTCBuyParamValue(NSString *buyParams, NSString *field)
{
    if (!buyParams.length || !field.length) {
        return nil;
    }
    NSString *needle = [field stringByAppendingString:@"="];
    for (NSString *pair in [buyParams componentsSeparatedByString:@"&"]) {
        if ([pair hasPrefix:needle]) {
            return [pair substringFromIndex:needle.length];
        }
    }
    return nil;
}

/// Faithful reproduction of AppStore++ 2.3.15's
/// `-[ASPDownloadVersionMetadataResolver startNativeCompatibilityPurchaseWithBuyParameters:]`.
///
/// This is the ONLY path that satisfies the store's purchase-level password
/// authorization (the 2071 BadPasswordToken dialog): it drives StoreKitUI's
/// native Buy action, which presents the Apple ID password sheet (identity
/// re-auth, NOT a price confirmation, because the request is a price=0
/// redownload). It never triggers 2FA and is not shown on every call.
///
/// SAFETY — this MUST NOT purchase anything, including a paid app the user has
/// never bought. The invariants below make a purchase structurally impossible:
///   G1  Only a `price=0` redownload buy-parameter string is accepted; any
///       non-zero price aborts before the request is built.
///   G2  The purchase is marked as an owned redownload
///       (usesLocalRedownloadParametersIfPossible + SSDownloadPropertyIsRedownload)
///       and createsDownloads / createsJobs / createsInstallJobs are NO on the
///       purchase and createsDownloads / createsJobs are NO on the request, whose
///       values overwrite the purchase's when it is sent.
///   G3  The request never validates the purchase (shouldValidatePurchases=NO),
///       so the charge/receipt pipeline is never entered.
///   G4  The response is only read for the signed IPA URL / version metadata;
///       a response that looks like a real purchase (non-redownload dialog, a
///       priced buy-confirm) is rejected instead of followed.
/// For an unowned paid app the server rejects the price=0 redownload outright,
/// which lands in G4 and is surfaced as "rejected" — no charge, no download.
- (void)nativeCompatibilityBuyForAdamID:(NSString *)adamId
                        externalVersionId:(NSString *)externalVersionId
                            buyParameters:(NSString *)buyParameters
                               completion:(void (^)(NSDictionary *plist, NSError *error))completion
{
    // StoreKitUI's native Buy presents UI and must be driven from the main
    // thread, so hop to main first (a background start triggers a main-thread assertion
    // that terminates the process with no crash log).
    if (![NSThread isMainThread]) {
        XLog(@"Services", @"nativeBuy: hopping to main thread");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self nativeCompatibilityBuyForAdamID:adamId
                                externalVersionId:externalVersionId
                                    buyParameters:buyParameters
                                       completion:completion];
        });
        return;
    }
    XLog(@"Services", @"nativeBuy: ENTER (main) adam=%@ ext=%@ bytesIn=%lu", adamId, externalVersionId ?: @"-", (unsigned long)buyParameters.length);

    Class purchaseClass = NSClassFromString(@"SSPurchase");
    Class requestClass = NSClassFromString(@"SSPurchaseRequest");
    if (!purchaseClass || !requestClass) {
        XLog(@"Services", @"nativeBuy: SSPurchase/SSPurchaseRequest unavailable");
        if (completion) completion(nil, ASTCError(18, @"The purchase request could not be started."));
        return;
    }

    NSNumber *dsid = [self activeAccountIdentifier];

    // G1: require a download-free price=0 redownload parameter string.
    NSString *bp = buyParameters.length ? buyParameters : [NSString stringWithFormat:
        @"productType=C&price=0&salableAdamId=%lld&pricingParameters=STDRDL&clientBuyId=1&installed=0%@",
        adamId.longLongValue,
        externalVersionId.length ? [@"&appExtVrsId=" stringByAppendingString:externalVersionId] : @""];
    NSString *priceValue = ASTCBuyParamValue(bp, @"price");
    if (priceValue && [priceValue doubleValue] != 0.0) {
        XLog(@"Services", @"nativeBuy: >>> ABORT — buyParams price=%@ is not zero; refusing to run a priced Buy", priceValue);
        if (completion) completion(nil, ASTCError(18, @"The purchase request could not be started."));
        return;
    }

    void (*sB)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    void (*sO)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    void (*sOO)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;

    id purchase = nil;
    id request = nil;
    @try {
        if ([purchaseClass respondsToSelector:NSSelectorFromString(@"purchaseWithBuyParameters:")]) {
            purchase = ((id (*)(id, SEL, id))objc_msgSend)(purchaseClass, NSSelectorFromString(@"purchaseWithBuyParameters:"), bp);
        }
        if (!purchase) {
            purchase = [purchaseClass new];
            if ([purchase respondsToSelector:NSSelectorFromString(@"setBuyParameters:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(purchase, NSSelectorFromString(@"setBuyParameters:"), bp);
            }
        }
        if (!purchase) {
            XLog(@"Services", @"nativeBuy: could not create SSPurchase");
            if (completion) completion(nil, ASTCError(18, @"The purchase request could not be started."));
            return;
        }
        XLog(@"Services", @"nativeBuy: SSPurchase created (%@)", NSStringFromClass([purchase class]));

        // These setters take NSNumber objects (2.3.15 wraps via numberWithLongLong:
        // before calling them); passing a raw long long crashes when the setter
        // retains the value as an object pointer.
        if ([purchase respondsToSelector:NSSelectorFromString(@"setItemID:")]) sO(purchase, NSSelectorFromString(@"setItemID:"), @(adamId.longLongValue));
        if (dsid && [purchase respondsToSelector:NSSelectorFromString(@"setAccountIdentifier:")]) sO(purchase, NSSelectorFromString(@"setAccountIdentifier:"), dsid);
        if (dsid && [purchase respondsToSelector:NSSelectorFromString(@"setOwnerAccountDSID:")]) sO(purchase, NSSelectorFromString(@"setOwnerAccountDSID:"), dsid);

        // G2: owned-redownload framing + forbid every download/install job.
        if ([purchase respondsToSelector:NSSelectorFromString(@"setUsesLocalRedownloadParametersIfPossible:")])
            sB(purchase, NSSelectorFromString(@"setUsesLocalRedownloadParametersIfPossible:"), YES);
        if ([purchase respondsToSelector:NSSelectorFromString(@"setValue:forDownloadProperty:")])
            sOO(purchase, NSSelectorFromString(@"setValue:forDownloadProperty:"), @YES, @"SSDownloadPropertyIsRedownload");
        for (NSString *s in @[@"setCreatesDownloads:", @"setCreatesJobs:", @"setCreatesInstallJobs:"])
            if ([purchase respondsToSelector:NSSelectorFromString(s)]) sB(purchase, NSSelectorFromString(s), NO);
        XLog(@"Services", @"nativeBuy: SSPurchase configured (redownload, no jobs)");

        request = ((id (*)(id, SEL, id))objc_msgSend)([requestClass alloc], NSSelectorFromString(@"initWithPurchases:"), @[purchase]);
        if (!request) {
            XLog(@"Services", @"nativeBuy: could not create SSPurchaseRequest");
            if (completion) completion(nil, ASTCError(18, @"The purchase request could not be started."));
            return;
        }

        // G3: never validate the purchase (no charge/receipt pipeline). YES on
        // needsAuthentication is 2.3.15's native default and is what makes iOS
        // put up the Apple ID password sheet; because price=0 it is a sign-in
        // prompt, not a "Buy for $X" confirmation.
        // G2 again: the request's values overwrite the purchase's when it is
        // sent, and they default to YES.
        if ([request respondsToSelector:NSSelectorFromString(@"setCreatesDownloads:")]) sB(request, NSSelectorFromString(@"setCreatesDownloads:"), NO);
        if ([request respondsToSelector:NSSelectorFromString(@"setCreatesJobs:")]) sB(request, NSSelectorFromString(@"setCreatesJobs:"), NO);
        if ([request respondsToSelector:NSSelectorFromString(@"setShouldValidatePurchases:")]) sB(request, NSSelectorFromString(@"setShouldValidatePurchases:"), NO);
        if ([request respondsToSelector:NSSelectorFromString(@"setNeedsAuthentication:")]) sB(request, NSSelectorFromString(@"setNeedsAuthentication:"), YES);
    } @catch (NSException *exception) {
        XLog(@"Services", @"nativeBuy: >>> setup threw %@ (%@)", exception.name, exception.reason);
        if (completion) completion(nil, ASTCError(18, @"The purchase request could not be started."));
        return;
    }

    UIApplicationState appState = [UIApplication sharedApplication].applicationState;
    XLog(@"Services", @"nativeBuy: starting StoreKitUI-compatible Buy (validation=NO createsDownloads=NO needsAuth=YES) adam=%@ ext=%@ bytes=%lu appState=%ld",
           adamId, externalVersionId ?: @"-", (unsigned long)bp.length, (long)appState);

    // Keep the request alive for the whole async operation: ARC would otherwise
    // release this local at method scope and cancel the in-flight purchase.
    static NSMutableArray *sLiveRequests;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sLiveRequests = [NSMutableArray array]; });
    if (request) [sLiveRequests addObject:request];
    __block id heldRequest = request;

    __block BOOL finished = NO;
    __block NSDictionary *resultPlist = nil;
    __block NSError *resultError = nil;
    void (^finishOnce)(void) = ^{
        if (finished) return;
        finished = YES;
        if (heldRequest) { [sLiveRequests removeObject:heldRequest]; heldRequest = nil; }
        if (completion) completion(resultPlist, resultError);
    };

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    // StoreServices calls this block with one argument, on a private queue. A
    // second declared parameter would be read from an unset register and
    // retained on entry, which crashes before the first line runs.
    void (^responseBlk)(id) = ^(id response) {
        XLog(@"Services", @"nativeBuy: responseBlk fired");
        @try {
            NSInteger status = 0;
            NSData *body = nil;
            id err = nil;
            @try { err = [response valueForKey:@"error"]; } @catch (__unused NSException *e) {}
            @try {
                id urlResponse = [response valueForKey:@"URLResponse"];
                body = [urlResponse valueForKey:@"bodyData"];
                status = [[urlResponse valueForKey:@"statusCode"] integerValue];
            } @catch (__unused NSException *e) {}
            if (![body isKindOfClass:[NSData class]]) {
                @try { body = [response valueForKey:@"bodyData"]; } @catch (__unused NSException *e) {}
            }
            XLog(@"Services", @"nativeBuy: response took %.2fs HTTP %ld bytes=%lu error=%@",
                   CFAbsoluteTimeGetCurrent() - start, (long)status,
                   (unsigned long)([body isKindOfClass:[NSData class]] ? body.length : 0), err ?: @"-");

            // G4: refuse to follow anything that is not a plain redownload answer.
            id plist = [body isKindOfClass:[NSData class]] && body.length
                           ? [NSPropertyListSerialization propertyListWithData:body options:0 format:NULL error:NULL]
                           : nil;
            NSDictionary *d = [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
            id dlg = d[@"dialog"];
            if ([dlg isKindOfClass:[NSDictionary class]]) {
                id okAct = ((NSDictionary *)dlg)[@"okButtonAction"];
                NSString *actBuyParams = [okAct isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)okAct)[@"buyParams"] : nil;
                NSString *actPrice = ASTCBuyParamValue(actBuyParams, @"price");
                if (actPrice && [actPrice doubleValue] != 0.0) {
                    XLog(@"Services", @"nativeBuy: >>> ABORT — response dialog carries a priced continuation (price=%@); not a redownload", actPrice);
                    resultError = ASTCError(18, @"The store answered with a priced purchase.");
                    finishOnce();
                    return;
                }
            }
            resultPlist = d;
            resultError = [err isKindOfClass:[NSError class]] ? err : nil;
            finishOnce();
        } @catch (NSException *exception) {
            XLog(@"Services", @"nativeBuy: >>> responseBlk threw %@ (%@)", exception.name, exception.reason);
            resultError = ASTCError(18, @"The purchase response could not be read.");
            finishOnce();
        }
    };
    void (^completionBlk)(void) = ^{
        // StoreServices fires this after the response block; the version report
        // is driven from the response block, so this is a no-op safety net.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (!finished) { XLog(@"Services", @"nativeBuy: completion fired with no response body; rejecting"); resultError = ASTCError(18, @"The purchase returned no response."); finishOnce(); }
        });
    };

    BOOL hasStart = [request respondsToSelector:NSSelectorFromString(@"startWithPurchaseResponseBlock:completionBlock:")];
    XLog(@"Services", @"nativeBuy: request=%@ respondsToStart=%d", NSStringFromClass([request class]), hasStart);
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(request,
                                                  NSSelectorFromString(@"startWithPurchaseResponseBlock:completionBlock:"),
                                                  responseBlk, completionBlk);
        XLog(@"Services", @"nativeBuy: start returned, process alive, awaiting auth/response");
    } @catch (NSException *exception) {
        XLog(@"Services", @"nativeBuy: start threw %@", exception.reason);
        resultError = ASTCError(18, @"The purchase request could not be started.");
        finishOnce();
    }

    // Hard timeout so the UI never spins forever if the dialog is dismissed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!finished) { XLog(@"Services", @"nativeBuy: timed out after 90s"); resultError = ASTCError(5, @"The store did not respond to the authorization."); finishOnce(); }
    });
}

#pragma mark - Local redownload install

/// Rewrites the appExtVrsId inside a buy-parameter string (or appends one).
- (NSString *)buyParameters:(NSString *)parameters
    replacingExternalVersionID:(NSString *)externalVersionId
{
    if (parameters.length == 0 || externalVersionId.length == 0) {
        return parameters;
    }
    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:@"appExtVrsId=[0-9]+" options:0 error:NULL];
    NSString *replacement = [NSString stringWithFormat:@"appExtVrsId=%@", externalVersionId];
    NSString *rewritten = [expression stringByReplacingMatchesInString:parameters
                                                               options:0
                                                                 range:NSMakeRange(0, parameters.length)
                                                          withTemplate:replacement];
    if ([rewritten rangeOfString:@"appExtVrsId="].location == NSNotFound) {
        rewritten = [rewritten stringByAppendingFormat:@"&appExtVrsId=%@", externalVersionId];
    }
    return rewritten;
}

/// Reads the purchase history row of an app. appstored stores the account's own
/// redownload parameters there; they are what the store expects for a silent
/// redownload.
- (void)fetchLocalRedownloadParametersForAdamID:(NSString *)adamId
                                      bundleID:(NSString *)bundleId
                                    completion:(void (^)(NSString *parameters))completion
{
    Class historyClass = NSClassFromString(@"ASDPurchaseHistory");
    Class queryClass = NSClassFromString(@"ASDPurchaseHistoryQuery");
    if (!historyClass || !queryClass) {
        completion(nil);
        return;
    }

    id history = ((id (*)(id, SEL))objc_msgSend)(historyClass, NSSelectorFromString(@"sharedInstance"));
    id query = [[queryClass alloc] init];
    if (!history || !query) {
        completion(nil);
        return;
    }
    NSNumber *dsid = [self activeAccountIdentifier];
    @try {
        if (dsid) {
            [query setValue:dsid forKey:@"accountID"];
        }
        if (adamId.length) {
            [query setValue:@[@(adamId.longLongValue)] forKey:@"storeIDs"];
        }
    } @catch (__unused NSException *exception) {
    }

    SEL selector = NSSelectorFromString(@"executeQuery:withResultHandler:");
    if (![history respondsToSelector:selector]) {
        XLog(@"Services", @"ASDPurchaseHistory has no executeQuery:withResultHandler:");
        completion(nil);
        return;
    }

    __block BOOL finished = NO;
    void (^handler)(NSArray *, NSError *) = ^(NSArray *apps, NSError *error) {
        if (finished) {
            return;
        }
        finished = YES;
        NSString *parameters = nil;
        for (id app in apps) {
            @try {
                NSString *appBundle = [app valueForKey:@"bundleID"];
                NSString *value = [app valueForKey:@"redownloadParams"];
                if ([value isKindOfClass:[NSString class]] && value.length
                    && (bundleId.length == 0 || [appBundle isEqualToString:bundleId])) {
                    parameters = value;
                    break;
                }
            } @catch (__unused NSException *exception) {
            }
        }
        XLog(@"Services", @"local redownload params for %@: %@", bundleId, parameters);
        completion(parameters);
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(history, selector, query, handler);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!finished) {
            finished = YES;
            XLog(@"Services", @"purchase history query timed out");
            completion(nil);
        }
    });
}

- (void)installVersionUsingLocalRedownloadParameters:(ASTCVersion *)version
                                          forAdamID:(NSString *)adamId
                                           bundleID:(NSString *)bundleId
                                         completion:(ASTCInstallHandler)completion
{
    [self fetchLocalRedownloadParametersForAdamID:adamId
                                         bundleID:bundleId
                                       completion:^(NSString *parameters) {
        if (parameters.length == 0) {
            if (completion) {
                completion(ASTCError(12, @"The account has no local redownload parameters for this app."));
            }
            return;
        }
        NSString *buyParameters = [self buyParameters:parameters
                              replacingExternalVersionID:version.externalVersionId];
        XLog(@"Services", @"local redownload install: %@", buyParameters);
        [self runRequestWithBuyParameters:buyParameters
                        createsDownloads:YES
                       forceLocalRedownload:YES
                               completion:^(NSDictionary *plist, NSError *error) {
            if (completion) {
                completion(error);
            }
        }];
    }];
}

- (BOOL)installWithAppStoreDaemon:(ASTCVersion *)version
                        forAdamID:(NSString *)adamId
                pricingParameters:(NSString *)pricingParameters
                       completion:(ASTCInstallHandler)completion
{
    Class purchaseClass = NSClassFromString(@"ASDPurchase");
    Class managerClass = NSClassFromString(@"ASDPurchaseManager");
    if (!purchaseClass || !managerClass) {
        return NO;
    }

    id purchase = [[purchaseClass alloc] init];
    if (!purchase) {
        return NO;
    }

    NSString *buyParameters = ASTCBuildBuyParameters(adamId, pricingParameters, version.externalVersionId, NO, [self activeAccountIdentifier]);
    NSNumber *accountIdentifier = [self activeAccountIdentifier];
    @try { [purchase setValue:buyParameters forKey:@"buyParameters"]; } @catch (__unused NSException *e) { return NO; }
    @try { [purchase setValue:accountIdentifier forKey:@"ownerDSID"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:accountIdentifier forKey:@"purchaserDSID"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:accountIdentifier forKey:@"accountIdentifier"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@(adamId.longLongValue) forKey:@"itemID"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@YES forKey:@"createsJobs"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@YES forKey:@"sendGUID"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@NO forKey:@"isUpdate"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@NO forKey:@"isBackgroundUpdate"]; } @catch (__unused NSException *e) {}
    @try { [purchase setValue:@NO forKey:@"isRedownload"]; } @catch (__unused NSException *e) {}

    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, NSSelectorFromString(@"sharedManager"));
    if (!manager) {
        return NO;
    }

    XLog(@"Services", @"ASDPurchase install: buyParams=%@", buyParameters);
    void (^handler)(id) = ^(id result) {
        XLog(@"Services", @"ASDPurchase result: %@", result);
        if (completion) {
            completion(nil);
        }
    };
    SEL selector = NSSelectorFromString(@"startPurchase:withResultHandler:");
    if (![manager respondsToSelector:selector]) {
        XLog(@"Services", @"ASDPurchaseManager has no startPurchase:withResultHandler:");
        return NO;
    }
    ((void (*)(id, SEL, id, id))objc_msgSend)(manager, selector, purchase, handler);
    return YES;
}

- (void)installVersion:(ASTCVersion *)version
              forAdamID:(NSString *)adamId
    pricingParameters:(NSString *)pricingParameters
           completion:(ASTCInstallHandler)completion
{
    XLog(@"Services", @"installing %@ (ext=%@) for %@", version.displayVersion, version.externalVersionId, adamId);

    // Preferred path: talk to appstored directly. Its purchase handling uses the
    // App Store's modern account session and honours appExtVrsId in the buy
    // parameters.
    if ([self installWithAppStoreDaemon:version
                              forAdamID:adamId
                      pricingParameters:pricingParameters
                             completion:completion]) {
        return;
    }

    // Fallback: legacy StoreServices purchase request.
    NSString *buyParameters = version.buyParams.length
        ? version.buyParams
        : ASTCBuildBuyParameters(adamId, pricingParameters, version.externalVersionId, NO, [self activeAccountIdentifier]);
    [self runRequestWithBuyParameters:buyParameters
                     createsDownloads:YES
                            completion:^(NSDictionary *plist, NSError *error) {
        XLog(@"Services", @"install response: %@", ASTCSummarizeCommerceResponse(plist, error));
        if (completion) {
            completion(error);
        }
    }];
}

@end

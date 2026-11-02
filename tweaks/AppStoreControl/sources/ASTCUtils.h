//
//  ASTCUtils.h
//  AppStoreControl
//

#import <Foundation/Foundation.h>

@interface ASTCUtils : NSObject

/// Resolves the lowercase country code of the current account's store and calls
/// `completion` on the main queue. Never fails: falls back to the system region,
/// then "us". Nothing is cached, so an account switch applies to the next call.
+ (void)loadStorefrontCountryCodeWithCompletion:(void (^)(NSString *countryCode))completion;

@end

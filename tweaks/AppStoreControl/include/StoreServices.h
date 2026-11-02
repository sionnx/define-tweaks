//
//  StoreServices.h
//  AppStoreControl
//
//  The iOS 17.3 StoreServices class messaged directly. Look it up with
//  NSClassFromString: the tweak does not link the private framework.
//

#ifndef ASTC_STORE_SERVICES_H
#define ASTC_STORE_SERVICES_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SSDevice : NSObject

+ (nullable instancetype)currentDevice;
- (void)sdk_loadStorefrontCountryCode:(void (^)(NSString *_Nullable countryCode, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* ASTC_STORE_SERVICES_H */

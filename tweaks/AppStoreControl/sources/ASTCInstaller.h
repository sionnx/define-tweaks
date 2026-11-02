//
//  ASTCInstaller.h
//  AppStoreControl
//
//  Turns a chosen ASTCVersion into an App Store install of exactly that build.
//

#import <Foundation/Foundation.h>
#import "ASTCModels.h"

typedef void (^ASTCInstallResultHandler)(NSError *error);

@interface ASTCInstaller : NSObject

+ (instancetype)sharedInstance;

/// Ask appstored to download and install `version` of `product`. The call
/// returns immediately; the completion fires when the store accepted or
/// rejected the request (the download itself keeps running in App Store).
- (void)installVersion:(ASTCVersion *)version
             ofProduct:(ASTCProduct *)product
            completion:(ASTCInstallResultHandler)completion;

@end

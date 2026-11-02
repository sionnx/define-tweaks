//
//  ASTCPackageInfoReader.h
//  AppStoreControl
//
//  Reads Payload/<App>.app/Info.plist out of a remote IPA with HTTP range
//  requests: the ZIP tail, the central directory (in chunks, stopping at the
//  Info.plist entry) and that one compressed entry. A few tens of kilobytes
//  instead of the whole package.
//

#import <Foundation/Foundation.h>

typedef void (^ASTCPackageInfoHandler)(NSDictionary *info, NSError *error);

@interface ASTCPackageInfoReader : NSObject

+ (instancetype)sharedInstance;

/// `completion` runs on a background queue.
- (void)readInfoPlistAtURL:(NSURL *)url completion:(ASTCPackageInfoHandler)completion;

@end

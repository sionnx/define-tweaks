//
//  ASTCLocalization.h
//  AppStoreControl
//

#import <Foundation/Foundation.h>

/// Returns the translation of `english` for the system language, or `english`
/// itself when there is none.
FOUNDATION_EXPORT NSString *ASTCLocalized(NSString *english);

//
//  ASTCVersionListViewController.h
//  AppStoreControl
//
//  The version chooser. One table view listing every build Apple still serves
//  for an app, with the installed build highlighted.
//

#import <UIKit/UIKit.h>
#import "ASTCModels.h"

@interface ASTCVersionListViewController : UITableViewController

- (instancetype)initWithAdamID:(NSString *)adamId
                      bundleId:(NSString *)bundleId
                          name:(NSString *)name;

/// Wraps the chooser in a navigation controller ready to be presented.
- (UINavigationController *)wrappedInNavigationController;

@end

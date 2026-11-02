//
//  ASTCAppPickerViewController.h
//  AppStoreControl
//
//  Entry point used when the tweak cannot tell which product page the user is
//  looking at: pick an installed app, then choose a version for it.
//

#import <UIKit/UIKit.h>

@interface ASTCAppPickerViewController : UITableViewController

- (UINavigationController *)wrappedInNavigationController;

@end

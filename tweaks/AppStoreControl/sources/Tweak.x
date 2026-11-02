//
//  Tweak.x
//  AppStoreControl
//
//  Injected into com.apple.AppStore. Adds a version chooser to the App Store:
//  long-press the Get/Update/Open button on a product page (or the account
//  button for the app picker) and AppStoreControl lists every build Apple still
//  serves for that app. Picking one asks appstored to download and install
//  that exact build through the normal App Store pipeline.
//
//  The tweak lives in the App Store process on purpose: it inherits Apple's
//  store session, cookies and appstored entitlements, which is what makes a
//  downgrade possible without Apple IDs, helper daemons or a backend.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ASTCLog.h"
#import "ASTCModels.h"
#import "ASTCStoreClient.h"
#import "ASTCStoreServices.h"
#import "ASTCInstaller.h"
#import "ASTCVersionListViewController.h"
#import "ASTCAppPickerViewController.h"

#pragma mark - Helpers

static NSString *const ASTCRecentAdamIDKey = @"to.define.appstorecontrol.recent.adamid";
static NSString *const ASTCRecentAdamIDDateKey = @"to.define.appstorecontrol.recent.date";
static NSString *const ASTCGestureKey = @"to.define.appstorecontrol.gesture";

static id ASTCAppStoreSharedStore(void)
{
    static id store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [NSUserDefaults standardUserDefaults];
    });
    return store;
}

/// Remembers the identifier of the product page the user is looking at. App
/// Store's Jet pages are Swift and their model objects are not reachable from
/// Objective-C, so the identifier is harvested from the page requests the App
/// Store makes while it renders the page.
static void ASTCTrackURL(NSURL *url)
{
    NSString *string = url.absoluteString;
    if (string.length == 0) {
        return;
    }
    BOOL looksLikeStorePage = [string containsString:@"apps.apple.com"]
        || [string containsString:@"/v1/catalog/"]
        || [string containsString:@"MZStorePlatform"];
    if (!looksLikeStorePage) {
        return;
    }

    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:@"(?:apps/|/id|\\bid)([0-9]{6,})"
                                                               options:0
                                                                 error:NULL];
    });
    NSTextCheckingResult *match = [expression firstMatchInString:string
                                                        options:0
                                                          range:NSMakeRange(0, string.length)];
    if (match.numberOfRanges < 2) {
        return;
    }
    NSString *adamId = [string substringWithRange:[match rangeAtIndex:1]];
    if (adamId.length < 6) {
        return;
    }
    NSUserDefaults *defaults = ASTCAppStoreSharedStore();
    NSString *previous = [defaults stringForKey:ASTCRecentAdamIDKey];
    [defaults setObject:adamId forKey:ASTCRecentAdamIDKey];
    [defaults setObject:[NSDate date] forKey:ASTCRecentAdamIDDateKey];
    if (![previous isEqualToString:adamId]) {
        ASTCLog(@"product page id: %@", adamId);
    }
}

/// The identifier is only trusted for a couple of minutes: pages prefetch
/// data for other apps.
static NSString *ASTCRecentAdamID(void)
{
    NSUserDefaults *defaults = ASTCAppStoreSharedStore();
    NSString *adamId = [defaults stringForKey:ASTCRecentAdamIDKey];
    NSDate *timestamp = [defaults objectForKey:ASTCRecentAdamIDDateKey];
    if (adamId.length == 0 || ![timestamp isKindOfClass:[NSDate class]]) {
        return nil;
    }
    if (-[timestamp timeIntervalSinceNow] > 180) {
        return nil;
    }
    return adamId;
}

static UIViewController *ASTCTopViewController(void)
{
    UIWindow *window = nil;
    for (UIWindow *candidate in [UIApplication sharedApplication].windows) {
        if (candidate.isKeyWindow) {
            window = candidate;
            break;
        }
    }
    window = window ?: [UIApplication sharedApplication].windows.firstObject;
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:[UITabBarController class]]) {
        controller = ((UITabBarController *)controller).selectedViewController ?: controller;
    }
    if ([controller isKindOfClass:[UINavigationController class]]) {
        controller = ((UINavigationController *)controller).topViewController ?: controller;
    }
    return controller;
}

static void ASTCPresentController(UIViewController *controller)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = ASTCTopViewController();
        if (!presenter || !controller) {
            ASTCLog(@"cannot present: no view controller");
            return;
        }
        [presenter presentViewController:controller animated:YES completion:nil];
    });
}

static NSString *ASTCPageTitle(void)
{
    UIViewController *controller = ASTCTopViewController();
    NSString *title = controller.navigationItem.title ?: controller.title;
    if (title.length == 0) {
        title = controller.navigationController.navigationBar.topItem.title;
    }
    return title;
}

/// Builds and presents the version chooser. UIKit objects must be created on
/// the main thread, so the whole construction happens there.
static void ASTCPresentVersionChooser(NSString *adamId, NSString *bundleId, NSString *name)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *presenter = ASTCTopViewController();
            if (!presenter) {
                ASTCLog(@"cannot present version chooser: no presenter");
                return;
            }
            ASTCVersionListViewController *controller =
                [[ASTCVersionListViewController alloc] initWithAdamID:adamId bundleId:bundleId name:name];
            UINavigationController *navigationController = [controller wrappedInNavigationController];
            [presenter presentViewController:navigationController animated:YES completion:nil];
            ASTCLog(@"presented version chooser for %@", adamId);
        } @catch (NSException *exception) {
            ASTCLog(@"presenting version chooser failed: %@", exception);
        }
    });
}

#pragma mark - Long press handling

@interface ASTCGestureHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *targetView;
- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer;
@end

@implementation ASTCGestureHandler

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    return YES;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer
{
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    UIView *view = recognizer.view ?: self.targetView;
    NSString *className = NSStringFromClass([view class]);
    ASTCLog(@"long press on %@", className);
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];

    if ([className containsString:@"AccountButton"]) {
        [self showAccountMenu];
        return;
    }
    [self showVersionChooserForCurrentPage];
}

- (void)showVersionChooserForCurrentPage
{
    NSString *adamId = ASTCRecentAdamID();
    NSString *title = ASTCPageTitle();
    if (adamId.length == 0) {
        [self showPickerWithMessage:@"The App Store did not tell AppStoreControl which app this page belongs to. Pick the app from the list instead."];
        return;
    }
    ASTCPresentVersionChooser(adamId, nil, title);
}

- (void)showPickerWithMessage:(NSString *)message
{
    if (message.length) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AppStoreControl"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"Choose App" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf showPicker];
        }]];
        ASTCPresentController(alert);
        return;
    }
    [self showPicker];
}

- (void)showPicker
{
    ASTCAppPickerViewController *picker = [ASTCAppPickerViewController new];
    ASTCPresentController([picker wrappedInNavigationController]);
}

- (void)showAccountMenu
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"AppStoreControl"
                                                                   message:@"Browse an app's version history and install any build Apple still serves."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Downgrade an App…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf showPicker];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Clear Version Cache" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[ASTCStoreClient sharedInstance] clearCacheForAdamID:nil];
        ASTCLog(@"version cache cleared");
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open Log" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *path = [NSString stringWithFormat:@"file://%@", [ASTCLogger logFilePath]];
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:path] options:@{} completionHandler:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *presenter = ASTCTopViewController();
    sheet.popoverPresentationController.sourceView = presenter.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
                                                                CGRectGetMidY(presenter.view.bounds), 1, 1);
    [presenter presentViewController:sheet animated:YES completion:nil];
}

@end

/// Adds the long-press gesture the first time a store button appears.
static void ASTCMaybeAttachLongPress(UIView *view)
{
    if (view.window == nil) {
        return;
    }
    static Class offerButtonClass;
    static Class accountButtonClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        offerButtonClass = NSClassFromString(@"_TtC8AppStore11OfferButton");
        accountButtonClass = NSClassFromString(@"_TtC8AppStore13AccountButton");
    });

    BOOL isOfferButton = offerButtonClass && [view isKindOfClass:offerButtonClass];
    BOOL isAccountButton = accountButtonClass && [view isKindOfClass:accountButtonClass];
    if (!isOfferButton && !isAccountButton) {
        return;
    }
    if (objc_getAssociatedObject(view, (__bridge const void *)ASTCGestureKey)) {
        return;
    }

    ASTCGestureHandler *handler = [ASTCGestureHandler new];
    handler.targetView = view;
    objc_setAssociatedObject(view, (__bridge const void *)ASTCGestureKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:handler
                                                                                        action:@selector(handleLongPress:)];
    press.minimumPressDuration = 0.45;
    // Cancel the button's own touch once the long press is recognized, or
    // lifting the finger also counts as a tap and starts the download.
    press.cancelsTouchesInView = YES;
    press.delegate = handler;
    [view addGestureRecognizer:press];
    ASTCLog(@"attached long press to %@", NSStringFromClass([view class]));
}


#pragma mark - Hooks

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler
{
    ASTCTrackURL(url);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler
{
    ASTCTrackURL(request.URL);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
{
    ASTCTrackURL(url);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
{
    ASTCTrackURL(request.URL);
    return %orig;
}

%end

%hook UIView

- (void)didMoveToWindow
{
    %orig;
    ASTCMaybeAttachLongPress(self);
}

%end

%ctor
{
    @autoreleasepool {
        ASTCLog(@"AppStoreControl loaded into %@ (store services %@)",
               [[NSBundle mainBundle] bundleIdentifier],
               [ASTCStoreServices isAvailable] ? @"available" : @"missing");
    }
}

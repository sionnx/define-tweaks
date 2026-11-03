//
//  ASTCVersionListViewController.m
//  AppStoreControl
//

#import "ASTCVersionListViewController.h"
#import "ASTCStoreClient.h"
#import "ASTCStoreServices.h"
#import "ASTCInstaller.h"
#import "ASTCLog.h"
#import "ASTCLocalization.h"

#import <objc/message.h>

@interface ASTCVersionListViewController ()
@property (nonatomic, copy) NSString *adamId;
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, strong) ASTCProduct *product;
/// Rows on screen: the cached list first, then each snapshot while probing.
@property (nonatomic, copy) NSArray<ASTCVersion *> *versions;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL resolving;
@property (nonatomic, copy) NSString *progressText;
/// Replaces the list when no lookup could run for this app.
@property (nonatomic, copy) NSString *statusMessage;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *footerLabel;
/// Build whose install request is running. Rows reload while probing, so the
/// spinner is tracked by build instead of by cell.
@property (nonatomic, copy) NSString *installingExternalVersionId;
@end

@implementation ASTCVersionListViewController

- (instancetype)initWithAdamID:(NSString *)adamId
                      bundleId:(NSString *)bundleId
                          name:(NSString *)name
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _adamId = [adamId copy];
        _bundleId = [bundleId copy];
        _displayName = [name copy];
    }
    return self;
}

- (UINavigationController *)wrappedInNavigationController
{
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:self];
    navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
    return navigationController;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    ASTCLog(@"version chooser visible: %lu rows, title=%@", (unsigned long)self.versions.count, self.title);
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    // The list closes by being dismissed, or popped when opened from the picker.
    if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed) {
        [[ASTCStoreClient sharedInstance] cancelVersionLookupForAdamID:self.adamId];
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = self.displayName.length ? self.displayName : @"Versions";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                          target:self
                                                                                          action:@selector(close:)];

    UIRefreshControl *refreshControl = [UIRefreshControl new];
    [refreshControl addTarget:self action:@selector(refresh:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refreshControl;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;

    [self startLoadingForceRefresh:NO];
}

/// Shows the bundle identifier centered above the version list, or a placeholder
/// while it is loading or after the load failed to provide it.
- (void)updateHeader
{
    NSString *bundleId = self.product.bundleId.length ? self.product.bundleId : self.bundleId;
    // The first call runs from viewDidLoad, before the table has been laid out.
    CGFloat width = self.tableView.bounds.size.width ?: [UIScreen mainScreen].bounds.size.width;
    // No space below the label: the section header above the list adds its own.
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 32)];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 12, width - 40, 20)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    label.text = bundleId.length ? bundleId : (self.loading ? @"Loading bundle ID…" : @"Failed to load bundle ID");
    [header addSubview:label];
    self.tableView.tableHeaderView = header;
}

- (void)close:(id)sender
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refresh:(UIRefreshControl *)refreshControl
{
    // A pull while loading would delete the cache the running load relies on.
    if (self.loading) {
        [refreshControl endRefreshing];
        return;
    }
    // Keep resolved builds: a refused lookup must not empty the list. Only the
    // builds given up on get another chance.
    ASTCLog(@"version chooser refresh: retrying skipped builds for %@", self.adamId);
    [[ASTCStoreClient sharedInstance] clearSkippedBuildsForAdamID:self.adamId];
    [self startLoadingForceRefresh:YES];
}

- (void)startLoadingForceRefresh:(BOOL)forceRefresh
{
    if (self.loading) {
        return;
    }
    self.loading = YES;
    self.statusMessage = nil;
    self.progressText = @"Reading version list from the App Store…";
    [self updateHeader];
    [self updateFooter];
    [self.tableView reloadData];

    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    ASTCLog(@"version chooser loading %@ (forceRefresh=%d)", self.adamId, forceRefresh);
    __weak typeof(self) weakSelf = self;
    [[ASTCStoreClient sharedInstance] fetchProductForAdamID:self.adamId
                                                 progress:^(NSUInteger resolved, NSUInteger total, ASTCProduct *product,
                                                            NSArray<ASTCVersion *> *versions) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL firstRows = strongSelf.versions.count == 0 && versions.count > 0;
            if (versions.count) {
                strongSelf.product = product;
                strongSelf.versions = versions;
            }
            strongSelf.progressText = total
                ? [NSString stringWithFormat:@"Checking versions… %lu/%lu", (unsigned long)resolved, (unsigned long)total]
                : @"Updating the version list…";
            if (firstRows) {
                ASTCLog(@"version chooser showed %lu cached versions after %.2fs",
                       (unsigned long)versions.count, CFAbsoluteTimeGetCurrent() - startTime);
                if (product.name.length) {
                    strongSelf.title = product.name;
                }
                [strongSelf updateHeader];
            }
            [strongSelf updateFooter];
            [strongSelf.tableView reloadData];
        });
    }
                                               completion:^(ASTCProduct *product, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ASTCLog(@"version chooser load took %.2fs: %lu versions, error=%@",
                   CFAbsoluteTimeGetCurrent() - startTime,
                   (unsigned long)product.versions.count, error.localizedDescription);
            strongSelf.loading = NO;
            [strongSelf.refreshControl endRefreshing];
            if ([error.domain isEqualToString:ASTCStoreClientErrorDomain] && error.code == ASTCStoreClientInstallStateErrorCode) {
                if (product.name.length) {
                    strongSelf.displayName = product.name;
                    strongSelf.title = product.name;
                }
                if (product.bundleId.length) {
                    strongSelf.bundleId = product.bundleId;
                }
                strongSelf.product = nil;
                strongSelf.versions = nil;
                strongSelf.statusMessage = error.localizedDescription;
                strongSelf.progressText = nil;
                [strongSelf updateHeader];
                [strongSelf updateFooter];
                [strongSelf.tableView reloadData];
                return;
            }
            // A failed refresh keeps the cached rows already on screen.
            if (!product || (error && product.versions.count == 0)) {
                strongSelf.progressText = error.localizedDescription ?: @"Unable to read the version list.";
                [strongSelf updateHeader];
                [strongSelf updateFooter];
                [strongSelf.tableView reloadData];
                return;
            }
            if (strongSelf.displayName.length == 0) {
                strongSelf.displayName = product.name;
            }
            strongSelf.title = product.name.length ? product.name : strongSelf.displayName;
            strongSelf.product = product;
            strongSelf.versions = product.versions;
            strongSelf.progressText = error.localizedDescription;
            [strongSelf updateHeader];
            [strongSelf updateFooter];
            [strongSelf.tableView reloadData];
            ASTCLog(@"version chooser loaded %lu versions for %@ (installed %@)",
                   (unsigned long)product.versions.count, product.name,
                   product.installedDisplayVersion ?: @"unknown");
        });
    }];
}

- (void)updateFooter
{
    if (self.progressText.length == 0) {
        self.tableView.tableFooterView = nil;
        return;
    }
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 64)];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(footer.bounds, 20, 8)];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    label.text = self.progressText;
    [footer addSubview:label];
    [self.spinner stopAnimating];
    self.tableView.tableFooterView = footer;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (self.versions.count == 0) {
        return 1;
    }
    return self.versions.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return self.product ? ASTCLocalized(@"Available Versions") : @"Status";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.versions.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.detailTextLabel.numberOfLines = 2;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (self.statusMessage.length) {
            cell.textLabel.numberOfLines = 0;
            cell.textLabel.text = self.statusMessage;
            return cell;
        }
        cell.textLabel.text = self.loading ? @"Resolving versions…" : @"No versions available";
        cell.detailTextLabel.text = self.progressText;
        return cell;
    }

    // Version on the first line; build, compatibility and install state below.
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    ASTCVersion *version = self.versions[indexPath.row];
    cell.textLabel.text = version.displayVersion ?: version.externalVersionId;
    cell.textLabel.textColor = version.isCompatible ? [UIColor labelColor] : [UIColor secondaryLabelColor];

    UIFont *detailFont = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    NSDictionary *detailAttributes = @{NSFontAttributeName : detailFont,
                                       NSForegroundColorAttributeName : [UIColor secondaryLabelColor]};
    NSMutableAttributedString *detail = [[NSMutableAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"Build %@", version.externalVersionId ?: @"-"]
            attributes:detailAttributes];
    [detail appendAttributedString:[[NSAttributedString alloc] initWithString:@" - " attributes:detailAttributes]];
    // The minimum OS version stays unknown until the IPA has been read.
    if (version.minimumOSVersion.length == 0) {
        [detail appendAttributedString:[[NSAttributedString alloc] initWithString:@"unknown" attributes:detailAttributes]];
    } else {
        NSString *compatibility = version.isCompatible
            ? ASTCLocalized(@"compatible")
            : [NSString stringWithFormat:@"requires iOS %@", version.minimumOSVersion];
        [detail appendAttributedString:[[NSAttributedString alloc]
            initWithString:compatibility
                attributes:@{NSFontAttributeName : detailFont,
                             NSForegroundColorAttributeName : version.isCompatible ? self.view.tintColor : [UIColor systemRedColor]}]];
    }
    if (version.isInstalled) {
        [detail appendAttributedString:[[NSAttributedString alloc] initWithString:[@" - " stringByAppendingString:ASTCLocalized(@"installed")] attributes:detailAttributes]];
    }
    cell.detailTextLabel.attributedText = detail;
    if (self.installingExternalVersionId && [version.externalVersionId isEqualToString:self.installingExternalVersionId]) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [indicator startAnimating];
        cell.accessoryView = indicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.versions.count == 0 || self.installingExternalVersionId) {
        return;
    }
    ASTCVersion *version = self.versions[indexPath.row];
    [self confirmInstallOfVersion:version];
}

- (void)confirmInstallOfVersion:(ASTCVersion *)version
{
    NSString *title = [NSString stringWithFormat:@"Install %@?", version.displayVersion];
    NSMutableString *message = [NSMutableString string];
    if (self.product.installedDisplayVersion.length) {
        [message appendFormat:@"Currently installed: %@\n", self.product.installedDisplayVersion];
    }
    [message appendFormat:@"Requested: %@ (Build %@)\n", version.displayVersion, version.externalVersionId];
    if (version.minimumOSVersion.length) {
        [message appendFormat:@"Requires iOS %@\n", version.minimumOSVersion];
    }
    [message appendString:@"\nThe App Store will download this build from Apple and install it over the current app. App data is kept."];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Install" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf installVersion:version];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)installVersion:(ASTCVersion *)version
{
    self.installingExternalVersionId = version.externalVersionId;
    [self.tableView reloadData];

    __weak typeof(self) weakSelf = self;
    [[ASTCInstaller sharedInstance] installVersion:version
                                        ofProduct:self.product
                                       completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (error) {
                strongSelf.installingExternalVersionId = nil;
                [strongSelf.tableView reloadData];
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Install failed"
                                                                               message:error.localizedDescription
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [strongSelf presentViewController:alert animated:YES completion:nil];
            } else {
                [strongSelf dismissViewControllerAnimated:YES completion:nil];
            }
        });
    }];
}

@end

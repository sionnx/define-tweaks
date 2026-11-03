//
//  ASTCAppPickerViewController.m
//  AppStoreControl
//

#import "ASTCAppPickerViewController.h"
#import "ASTCStoreClient.h"
#import "ASTCVersionListViewController.h"

@interface ASTCAppPickerViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<ASTCInstalledApp *> *allApps;
@property (nonatomic, strong) NSArray<ASTCInstalledApp *> *filteredApps;
@end

@implementation ASTCAppPickerViewController

- (UINavigationController *)wrappedInNavigationController
{
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:self];
    navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
    return navigationController;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Choose an App";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                          target:self
                                                                                          action:@selector(close:)];

    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.searchResultsUpdater = self;
    searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = searchController;
    self.definesPresentationContext = YES;

    self.allApps = [[ASTCStoreClient sharedInstance] installedApps];
    self.filteredApps = self.allApps;
}

- (void)close:(id)sender
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *query = searchController.searchBar.text;
    if (query.length == 0) {
        self.filteredApps = self.allApps;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@ OR bundleId CONTAINS[cd] %@", query, query];
        self.filteredApps = [self.allApps filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    ASTCInstalledApp *app = self.filteredApps[indexPath.row];
    cell.textLabel.text = app.name;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  %@", app.version ?: @"?", app.bundleId];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ASTCInstalledApp *app = self.filteredApps[indexPath.row];
    if (app.adamId.length) {
        [self pushVersionsForAdamID:app.adamId bundleId:app.bundleId name:app.name];
        return;
    }

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    cell.accessoryView = spinner;
    [spinner startAnimating];

    __weak typeof(self) weakSelf = self;
    [[ASTCStoreClient sharedInstance] resolveAdamIDForBundleID:app.bundleId completion:^(NSString *adamId, NSString *bundleId, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            cell.accessoryView = nil;
            if (!strongSelf) {
                return;
            }
            if (adamId.length == 0) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"App not found"
                                                                               message:error.localizedDescription ?: @"This app is not available on the App Store."
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [strongSelf presentViewController:alert animated:YES completion:nil];
                return;
            }
            [strongSelf pushVersionsForAdamID:adamId bundleId:bundleId ?: app.bundleId name:app.name];
        });
    }];
}

- (void)pushVersionsForAdamID:(NSString *)adamId bundleId:(NSString *)bundleId name:(NSString *)name
{
    ASTCVersionListViewController *controller = [[ASTCVersionListViewController alloc] initWithAdamID:adamId
                                                                                           bundleId:bundleId
                                                                                               name:name];
    [self.navigationController pushViewController:controller animated:YES];
}

@end

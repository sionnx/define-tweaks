// DockReel — runtime capability checks, so one build covers every supported iOS.
// Differences are detected by probing the system instead of comparing iOS versions.

#import <UIKit/UIKit.h>
#import "SpringBoard.h"

// Selects the APIs to use and checks the required ones exist. Call once before
// %init; NO means this system is unsupported and the dock must stay stock.
BOOL DRCompatPrepare(void);

// The list size SpringBoard derives the dock's icon spacing from.
CGSize DRSpacingListSize(SBIconListGridLayoutConfiguration *config);
void DRSetSpacingListSize(SBIconListGridLayoutConfiguration *config, CGSize size);

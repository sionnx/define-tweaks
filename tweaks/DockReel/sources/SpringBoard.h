// Private SpringBoard / SpringBoardHome declarations used by DockReel,
// checked against the iOS 17.3 (21D50) and 27.0.1 (24A446) headers in references/ipsws.

#import <UIKit/UIKit.h>

typedef struct SBHIconGridSize {
	uint16_t columns;
	uint16_t rows;
} SBHIconGridSize;

typedef struct SBIconImageInfo {
	CGSize size;
	CGFloat scale;
	CGFloat continuousCornerRadius;
} SBIconImageInfo;

typedef struct SBIconCoordinate {
	long long col;
	long long row;
} SBIconCoordinate;

@interface SBIconListGridLayoutConfiguration : NSObject
@property (assign, nonatomic) NSUInteger numberOfPortraitRows;
@property (assign, nonatomic) NSUInteger numberOfPortraitColumns;
@property (assign, nonatomic) UIEdgeInsets portraitLayoutInsets;
@property (assign, nonatomic) SBIconImageInfo iconImageInfo;
// Which of these two exists depends on the system; use DRSpacingListSize in DRCompat.h.
@property (assign, nonatomic) CGSize listSizeForIconSpacingCalculation;
@property (assign, nonatomic) CGSize portraitListSizeForIconSpacingCalculation;
@end

@interface SBIconListFlowLayout : NSObject
@property (nonatomic, readonly, copy) SBIconListGridLayoutConfiguration *layoutConfiguration;
@end

@interface SBIconListModel : NSObject
- (NSUInteger)maxNumberOfIcons;
- (NSUInteger)numberOfIcons;
- (SBHIconGridSize)gridSize;
- (void)setGridSize:(SBHIconGridSize)size;
@end

@interface SBIconListViewLayoutMetrics : NSObject
@property (nonatomic) CGSize iconSize;
@end

@interface SBIconListView : UIView
@property (nonatomic, retain) SBIconListModel *model;
@property (nonatomic, retain) id layout;
@property (nonatomic) long long layoutInsetsMode;
@property (nonatomic) CGSize iconSpacing;
- (BOOL)isEditing;
- (void)layoutIconsNow;
- (void)enumerateIconViewsUsingBlock:(void (^)(UIView *iconView, BOOL *stop))block;
@end

@interface SBDockIconListView : SBIconListView
@end

@interface SBDockView : UIView
@property (nonatomic, readonly) SBDockIconListView *dockListView;
@end

// The icon list's UIDropInteraction delegate.
@interface SBIconListViewDraggingDestinationDelegate : NSObject
@property (nonatomic, readonly, weak) SBIconListView *iconListView;
@end

// FrontBoard: used to restart SpringBoard after the switch is toggled
@interface FBSystemService : NSObject
+ (instancetype)sharedInstance;
- (void)exitAndRelaunch:(BOOL)relaunch;
@end

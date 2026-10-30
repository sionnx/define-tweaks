// DockReel — the paging scroll view that hosts the dock icon list.

#import <UIKit/UIKit.h>
#import "SpringBoard.h"

@interface DRDockScrollView : UIScrollView <UIScrollViewDelegate>
@property (nonatomic, weak) SBIconListView *listView;
@property (nonatomic, assign) NSInteger currentPage;
// Frame SpringBoard wants for the dock list, in SBDockView coordinates.
@property (nonatomic, assign) CGRect dockFrame;
@property (nonatomic, assign) NSInteger pageCount;
@property (nonatomic, assign) NSInteger edgeDirection;
@property (nonatomic, strong) NSTimer *edgeTimer;
// Free scrolling mode: no paging, scrolling stops wherever it lands; content length is based on the number of icon slots
@property (nonatomic, assign) BOOL freeMode;
@property (nonatomic, assign) NSInteger slotCount;
@property (nonatomic, assign) CGFloat edgeSpeed;
@property (nonatomic, strong) CADisplayLink *edgeLink;
- (void)dr_setPageCount:(NSInteger)count animated:(BOOL)animated;
- (void)dr_setSlotCount:(NSInteger)count pitch:(CGFloat)pitch animated:(BOOL)animated;
- (void)dr_dragMovedToPoint:(CGPoint)point;
- (void)dr_dragEnded;
@end

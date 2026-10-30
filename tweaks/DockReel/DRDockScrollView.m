// DockReel — paging and edge page-turn while dragging.

#import "DRDockScrollView.h"
#import "DockReel.h"

@implementation DRDockScrollView

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.pagingEnabled = YES;
		self.showsHorizontalScrollIndicator = NO;
		self.showsVerticalScrollIndicator = NO;
		self.alwaysBounceVertical = NO;
		self.alwaysBounceHorizontal = YES;
		self.directionalLockEnabled = YES;
		self.scrollsToTop = NO;
		self.delaysContentTouches = NO;
		self.canCancelContentTouches = YES;
		self.clipsToBounds = YES;
		self.decelerationRate = UIScrollViewDecelerationRateFast;
		self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
		self.delegate = self;
		self.pageCount = 1;
	}
	return self;
}

- (void)setFreeMode:(BOOL)freeMode {
	_freeMode = freeMode;
	self.pagingEnabled = !freeMode;
	self.decelerationRate = freeMode ? UIScrollViewDecelerationRateNormal : UIScrollViewDecelerationRateFast;
}

- (CGFloat)dr_maxOffset {
	return MAX(0, self.contentSize.width - CGRectGetWidth(self.bounds));
}

// Free scrolling mode: one screen holds 4 slots; each extra slot adds one slot pitch to the content
- (void)dr_setSlotCount:(NSInteger)count pitch:(CGFloat)pitch animated:(BOOL)animated {
	count = MAX(1, MIN(count, DR_MAX_ICONS));
#if DR_DEBUG
	if (count != self.slotCount) DRLog(@"slotCount %ld -> %ld (offset %.1f)", (long)self.slotCount, (long)count, self.contentOffset.x);
#endif
	self.slotCount = count;
	self.scrollEnabled = count > DR_ICONS_PER_PAGE;
	CGFloat width = CGRectGetWidth(self.bounds);
	if (width <= 0 || pitch <= 0) return;

	CGFloat extra = MAX(0, count - DR_ICONS_PER_PAGE) * pitch;
	CGSize contentSize = CGSizeMake(width + extra, CGRectGetHeight(self.bounds));
	if (!CGSizeEqualToSize(self.contentSize, contentSize)) self.contentSize = contentSize;

	// Scroll back into range when the trailing empty slot disappears (leaving edit mode)
	if (self.contentOffset.x > extra + 0.5) {
		[self setContentOffset:CGPointMake(extra, 0) animated:animated];
	}
}

- (void)dr_setPageCount:(NSInteger)count animated:(BOOL)animated {
	count = MAX(1, MIN(count, DR_MAX_PAGES));
#if DR_DEBUG
	if (count != self.pageCount) DRLog(@"pageCount %ld -> %ld (offset %.1f)", (long)self.pageCount, (long)count, self.contentOffset.x);
#endif
	self.pageCount = count;
	self.scrollEnabled = count > 1;
	CGFloat pageWidth = CGRectGetWidth(self.bounds);
	if (pageWidth <= 0) return;

	CGSize contentSize = CGSizeMake(pageWidth * count, CGRectGetHeight(self.bounds));
	if (!CGSizeEqualToSize(self.contentSize, contentSize)) self.contentSize = contentSize;

	// The page we are on went away (e.g. the blank edit page): slide back.
	CGFloat maxOffset = pageWidth * (count - 1);
	if (self.contentOffset.x > maxOffset + 0.5) {
		[self setContentOffset:CGPointMake(maxOffset, 0) animated:animated];
	}
}

- (void)dr_scrollToPage:(NSInteger)page {
	page = MAX(0, MIN(page, self.pageCount - 1));
	[self setContentOffset:CGPointMake(CGRectGetWidth(self.bounds) * page, 0) animated:YES];
}

// point is in the clip view's (platter's) coordinates.
- (void)dr_dragMovedToPoint:(CGPoint)point {
	if (self.freeMode) {
		[self dr_freeDragMovedToPoint:point];
		return;
	}
	CGFloat width = CGRectGetWidth(self.superview.bounds);
	NSInteger direction = 0;
	if (point.x < DR_EDGE_ZONE && self.currentPage > 0) {
		direction = -1;
	} else if (point.x > width - DR_EDGE_ZONE && self.currentPage < self.pageCount - 1) {
		direction = 1;
	}
	if (direction == self.edgeDirection) return;
#if DR_DEBUG
	DRLog(@"edge direction %ld at x=%.1f (width %.1f)", (long)direction, point.x, width);
#endif

	[self.edgeTimer invalidate];
	self.edgeTimer = nil;
	self.edgeDirection = direction;
	if (direction == 0) return;

	self.edgeTimer = [NSTimer timerWithTimeInterval:DR_EDGE_REPEAT_DELAY target:self
		selector:@selector(dr_edgeTimerFired:) userInfo:nil repeats:YES];
	self.edgeTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:DR_EDGE_FIRST_DELAY];
	[[NSRunLoop mainRunLoop] addTimer:self.edgeTimer forMode:NSRunLoopCommonModes];
}

- (void)dr_edgeTimerFired:(NSTimer *)timer {
	NSInteger target = self.currentPage + self.edgeDirection;
#if DR_DEBUG
	DRLog(@"edge turn %ld -> %ld", (long)self.currentPage, (long)target);
#endif
	// A drag can end without any drop callback reaching us (e.g. cancelled by
	// going home); never keep turning pages once the dock is no longer editing.
	BOOL editing = [self.listView respondsToSelector:@selector(isEditing)] && [self.listView isEditing];
	if (target < 0 || target >= self.pageCount || !self.window || !editing) {
		[self dr_dragEnded];
		return;
	}
	[self dr_scrollToPage:target];
}

// Free scrolling mode: keep scrolling while hovering in the edge zone, faster closer to the edge; stop after leaving it
- (void)dr_freeDragMovedToPoint:(CGPoint)point {
	CGFloat width = CGRectGetWidth(self.superview.bounds);
	CGFloat offset = self.contentOffset.x;
	CGFloat speed = 0;
	if (point.x < DR_EDGE_ZONE && offset > 0) {
		speed = -DR_FREE_EDGE_MAX_SPEED * MIN(1, (DR_EDGE_ZONE - point.x) / DR_EDGE_ZONE);
	} else if (point.x > width - DR_EDGE_ZONE && offset < [self dr_maxOffset]) {
		speed = DR_FREE_EDGE_MAX_SPEED * MIN(1, (point.x - (width - DR_EDGE_ZONE)) / DR_EDGE_ZONE);
	}
	self.edgeSpeed = speed;

	if (speed != 0 && !self.edgeLink) {
#if DR_DEBUG
		DRLog(@"free edge scroll start speed=%.0f at x=%.1f", speed, point.x);
#endif
		self.edgeLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(dr_edgeLinkFired:)];
		[self.edgeLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	} else if (speed == 0 && self.edgeLink) {
		[self dr_stopEdgeLink];
	}
}

- (void)dr_edgeLinkFired:(CADisplayLink *)link {
	// A drag can end without any callback (e.g. going back home); stop once editing ends
	BOOL editing = [self.listView respondsToSelector:@selector(isEditing)] && [self.listView isEditing];
	if (!self.window || !editing) {
		[self dr_dragEnded];
		return;
	}
	CGFloat dt = link.targetTimestamp - link.timestamp;
	if (dt <= 0 || dt > 0.1) dt = link.duration;
	CGFloat maxOffset = [self dr_maxOffset];
	CGFloat x = MAX(0, MIN(self.contentOffset.x + self.edgeSpeed * dt, maxOffset));
	self.contentOffset = CGPointMake(x, 0);
	if (x <= 0 || x >= maxOffset) [self dr_stopEdgeLink];
}

- (void)dr_stopEdgeLink {
	[self.edgeLink invalidate];
	self.edgeLink = nil;
	self.edgeSpeed = 0;
}

- (void)dr_dragEnded {
	[self.edgeTimer invalidate];
	self.edgeTimer = nil;
	self.edgeDirection = 0;
	[self dr_stopEdgeLink];
}

// Let taps / long presses on icons win over the pan.
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
	return YES;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
	CGFloat pageWidth = CGRectGetWidth(self.bounds);
	if (pageWidth > 0) {
		NSInteger page = (NSInteger)lround(self.contentOffset.x / pageWidth);
		self.currentPage = MAX(0, MIN(page, self.pageCount - 1));
	}
}

@end

// DockReel — scrollable dock with more than 4 icons, paged or free scrolling (iOS 17, SpringBoard).
// Hooks and dock setup; see DRDockScrollView.m for scrolling logic.
//
// How it works:
//   1. The dock's grid layout is widened to DR_MAX_ICONS columns (one row), and
//      the dock list model is allowed to hold that many icons.
//   2. SBDockIconListView is re-parented into a paging UIScrollView (clipped to
//      the dock platter) and made DR_MAX_PAGES pages wide. The scrollable range
//      only covers the pages actually in use: ceil(icons / 4), plus one blank
//      page while editing. A single page does not scroll.
//   3. Each page reuses the stock 4-icon dock inset and spacing; page N is the
//      same layout shifted right by N page widths.
//   4. While dragging an icon, resting near the platter's left/right edge turns
//      the page.
//
// 无极模式（设置页「滚动模式」）是另一套独立样式，不影响上面的分页逻辑：
//   - 所有图标按原版边距和间距等距排成一长条，不分页；
//   - 松手后保留惯性，但最终停在格距整数倍上，最左边的图标总是完整露出；
//   - 编辑时末尾多一个空位；拖图标停在边缘区内持续滚动。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DockReel.h"
#import "SpringBoard.h"
#import "DRDockScrollView.h"

static NSString *const kDRDockLocation = @"SBIconLocationDock";
static const void *kDRScrollKey = &kDRScrollKey;
static const void *kDRClipKey = &kDRClipKey;
static const void *kDRDockConfigKey = &kDRDockConfigKey;

static __weak SBIconListModel *gDockModel = nil;
// Stock dock left/right inset, captured before we touch the layout config.
static CGFloat gStockInset = 0;
// 无极模式开关（启动时从设置读取）和一屏宽度（原版 Dock 列表宽度）
static BOOL gFreeMode = NO;
static CGFloat gPageWidth = 0;

#pragma mark - Helpers

static SBIconListGridLayoutConfiguration *DRLayoutConfig(SBIconListView *listView) {
	if (![listView respondsToSelector:@selector(layout)]) return nil;
	id layout = listView.layout;
	if (![layout respondsToSelector:@selector(layoutConfiguration)]) return nil;
	return [layout layoutConfiguration];
}

static void DRMarkDockConfig(SBIconListGridLayoutConfiguration *config) {
	if (!config) return;
	objc_setAssociatedObject(config, kDRDockConfigKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL DRIsDockConfig(SBIconListGridLayoutConfiguration *config) {
	return [objc_getAssociatedObject(config, kDRDockConfigKey) boolValue];
}

static BOOL DRIsDockModel(SBIconListModel *model) {
	return model && model == gDockModel;
}

static DRDockScrollView *DRScrollViewForList(UIView *listView) {
	UIView *superview = listView.superview;
	return [superview isKindOfClass:[DRDockScrollView class]] ? (DRDockScrollView *)superview : nil;
}

static BOOL DRIsEditing(SBIconListView *listView) {
	return [listView respondsToSelector:@selector(isEditing)] && [listView isEditing];
}

// ceil(icons / 4) pages, plus one blank page while the home screen is editing.
static NSInteger DRWantedPageCount(SBIconListView *listView) {
	NSUInteger icons = [listView respondsToSelector:@selector(model)] ? [listView.model numberOfIcons] : 0;
	NSInteger pages = MAX((NSInteger)1, (NSInteger)((icons + DR_ICONS_PER_PAGE - 1) / DR_ICONS_PER_PAGE));
	if (DRIsEditing(listView)) pages += 1;
	return MIN(pages, (NSInteger)DR_MAX_PAGES);
}

// 无极模式：原版 4 图标 Dock 的图标间距，以及图标格距（图标宽 + 间距）
static CGFloat DRFreeSpacing(CGFloat pageWidth, CGFloat iconWidth) {
	return (pageWidth - 2 * gStockInset - DR_ICONS_PER_PAGE * iconWidth) / (DR_ICONS_PER_PAGE - 1);
}

static CGFloat DRIconWidth(SBIconListView *listView) {
	SBIconListGridLayoutConfiguration *config = DRLayoutConfig(listView);
	return config ? config.iconImageInfo.size.width : 0;
}

static CGFloat DRFreePitch(SBIconListView *listView, CGFloat pageWidth) {
	CGFloat iconWidth = DRIconWidth(listView);
	if (gStockInset <= 0 || iconWidth <= 0 || pageWidth <= 0) return 0;
	return iconWidth + DRFreeSpacing(pageWidth, iconWidth);
}

// 无极模式：图标数，编辑时末尾多一个空位
static NSInteger DRWantedSlotCount(SBIconListView *listView) {
	NSUInteger icons = [listView respondsToSelector:@selector(model)] ? [listView.model numberOfIcons] : 0;
	NSInteger slots = (NSInteger)icons + (DRIsEditing(listView) ? 1 : 0);
	return MAX((NSInteger)1, MIN(slots, (NSInteger)DR_MAX_ICONS));
}

// 列表视图的总宽度：分页模式为 DR_MAX_PAGES 页；无极模式正好容纳 DR_MAX_ICONS 个图标加两端边距，
// 这样系统按「居中全部列」排出的网格（用于点击和拖放定位）与图标实际位置一致
static CGFloat DRListWidth(SBIconListView *listView, CGFloat pageWidth) {
	if (gFreeMode) {
		CGFloat pitch = DRFreePitch(listView, pageWidth);
		if (pitch > 0) return 2 * gStockInset + DR_MAX_ICONS * pitch - DRFreeSpacing(pageWidth, DRIconWidth(listView));
	}
	return pageWidth * DR_MAX_PAGES;
}

static void DRUpdatePages(SBIconListView *listView, BOOL animated) {
	DRDockScrollView *scrollView = DRScrollViewForList(listView);
	if (!scrollView) return;
	if (gFreeMode) {
		NSInteger slots = DRWantedSlotCount(listView);
		if (slots != scrollView.slotCount || scrollView.contentSize.width <= 0) {
			[scrollView dr_setSlotCount:slots pitch:DRFreePitch(listView, CGRectGetWidth(scrollView.bounds)) animated:animated];
		}
		return;
	}
	NSInteger wanted = DRWantedPageCount(listView);
	if (wanted != scrollView.pageCount || scrollView.contentSize.width <= 0) {
		[scrollView dr_setPageCount:wanted animated:animated];
	}
}

static SBIconListView *DRDockListView(SBDockView *dockView) {
	if ([dockView respondsToSelector:@selector(dockListView)]) return dockView.dockListView;
	@try {
		return [dockView valueForKey:@"_iconListView"];
	} @catch (__unused NSException *e) {
		return nil;
	}
}

// Make icon pitch exactly pageWidth / 4 so every page lines up identically.
// SpringBoard derives the dock's iconSpacing from listSizeForIconSpacingCalculation
// (the screen size) and the column count, so with 8 columns that width has to
// cover both pages, otherwise the spacing goes negative and icons overlap.
static BOOL DRTuneSpacing(SBIconListView *listView, SBIconListGridLayoutConfiguration *config, CGFloat pageWidth) {
	if (!config || pageWidth <= 0) return NO;
	CGFloat iconWidth = config.iconImageInfo.size.width;
	if (iconWidth <= 0) return NO;
	CGFloat gap = pageWidth / DR_ICONS_PER_PAGE - iconWidth;
	if (gap < 0) return NO;
	BOOL changed = NO;

	UIEdgeInsets insets = config.portraitLayoutInsets;
	if (fabs(insets.left - gap / 2.0) >= 0.5 || fabs(insets.right - gap / 2.0) >= 0.5) {
		insets.left = gap / 2.0;
		insets.right = gap / 2.0;
		config.portraitLayoutInsets = insets;
		changed = YES;
	}

	if ([config respondsToSelector:@selector(listSizeForIconSpacingCalculation)]) {
		CGSize listSize = config.listSizeForIconSpacingCalculation;
		CGFloat wanted = pageWidth * DR_MAX_PAGES;
		if (fabs(listSize.width - wanted) >= 0.5) {
			listSize.width = wanted;
			config.listSizeForIconSpacingCalculation = listSize;
			changed = YES;
		}
	}

	if ([listView respondsToSelector:@selector(iconSpacing)]) {
		CGSize spacing = listView.iconSpacing;
		if (fabs(spacing.width - gap) >= 0.01) {
			spacing.width = gap;
			listView.iconSpacing = spacing;
			changed = YES;
		}
	}
	return changed;
}

// 无极模式：网格两端用原版边距、间距用原版间距，列表宽度正好容纳全部列
static BOOL DRTuneFreeSpacing(SBIconListView *listView, SBIconListGridLayoutConfiguration *config, CGFloat pageWidth) {
	if (!config || pageWidth <= 0 || gStockInset <= 0) return NO;
	CGFloat iconWidth = config.iconImageInfo.size.width;
	if (iconWidth <= 0) return NO;
	CGFloat gap = DRFreeSpacing(pageWidth, iconWidth);
	if (gap < 0) return NO;
	BOOL changed = NO;

	UIEdgeInsets insets = config.portraitLayoutInsets;
	if (fabs(insets.left - gStockInset) >= 0.01 || fabs(insets.right - gStockInset) >= 0.01) {
		insets.left = gStockInset;
		insets.right = gStockInset;
		config.portraitLayoutInsets = insets;
		changed = YES;
	}

	if ([config respondsToSelector:@selector(listSizeForIconSpacingCalculation)]) {
		CGSize listSize = config.listSizeForIconSpacingCalculation;
		CGFloat wanted = DRListWidth(listView, pageWidth);
		if (fabs(listSize.width - wanted) >= 0.01) {
			listSize.width = wanted;
			config.listSizeForIconSpacingCalculation = listSize;
			changed = YES;
		}
	}

	if ([listView respondsToSelector:@selector(iconSpacing)]) {
		CGSize spacing = listView.iconSpacing;
		if (fabs(spacing.width - gap) >= 0.01) {
			spacing.width = gap;
			listView.iconSpacing = spacing;
			changed = YES;
		}
	}
	return changed;
}

static UIView *DRPlatterView(SBDockView *dockView) {
	@try {
		return [dockView valueForKey:@"backgroundView"];
	} @catch (__unused NSException *e) {
		return nil;
	}
}

// The platter's rounded corner usually lives on a material subview.
static CGFloat DRCornerRadius(UIView *view, int depth) {
	CGFloat radius = view.layer.cornerRadius;
	if (depth > 0) {
		for (UIView *sub in view.subviews) radius = MAX(radius, DRCornerRadius(sub, depth - 1));
	}
	return radius;
}

// Clip the paging scroll view to the dock platter so icons never slide past
// its rounded edges.
static void DRLayoutClip(SBDockView *dockView, UIView *clipView, DRDockScrollView *scrollView, CGRect intended) {
	UIView *platter = DRPlatterView(dockView);
	CGRect clipFrame = intended;
	CGFloat radius = 0;
	if (platter && platter.superview == dockView && CGRectGetWidth(platter.frame) > 100) {
		clipFrame = platter.frame;
		radius = DRCornerRadius(platter, 3);
	}
	if (!CGRectEqualToRect(clipView.frame, clipFrame)) clipView.frame = clipFrame;
	if (fabs(clipView.layer.cornerRadius - radius) > 0.01) clipView.layer.cornerRadius = radius;

	CGRect scrollFrame = CGRectOffset(intended, -CGRectGetMinX(clipFrame), -CGRectGetMinY(clipFrame));
	if (!CGRectEqualToRect(scrollView.frame, scrollFrame)) scrollView.frame = scrollFrame;
	scrollView.dockFrame = intended;
}

static void DRSetupDock(SBDockView *dockView) {
	SBIconListView *listView = DRDockListView(dockView);
	if (!listView) return;

	// Capture the stock inset before DRTuneSpacing / DRTuneFreeSpacing rewrite it.
	SBIconListGridLayoutConfiguration *config = DRLayoutConfig(listView);
	if (config && gStockInset <= 0) gStockInset = config.portraitLayoutInsets.left;

	if ([listView respondsToSelector:@selector(model)]) {
		SBIconListModel *model = listView.model;
		gDockModel = model;
		if ([model respondsToSelector:@selector(setGridSize:)]) {
			SBHIconGridSize size = [model gridSize];
			if (size.columns != DR_MAX_ICONS) {
				[model setGridSize:(SBHIconGridSize){ DR_MAX_ICONS, 1 }];
			}
		}
	}

	DRDockScrollView *scrollView = objc_getAssociatedObject(dockView, kDRScrollKey);
	UIView *clipView = objc_getAssociatedObject(dockView, kDRClipKey);
	CGRect intended;

	if (!scrollView) {
		// Early in boot the dock has no real size yet; wait for a proper pass.
		if (CGRectGetWidth(listView.frame) < 100) return;
#if DR_DEBUG
		DRDumpListView(listView, @"stock (before setup)");
#endif
		intended = listView.frame;
		UIView *parent = listView.superview;
		if (!parent) return;
		clipView = [[UIView alloc] initWithFrame:intended];
		clipView.clipsToBounds = YES;
		clipView.layer.cornerCurve = kCACornerCurveContinuous;
		scrollView = [[DRDockScrollView alloc] initWithFrame:clipView.bounds];
		scrollView.freeMode = gFreeMode;
		scrollView.listView = listView;
		[parent insertSubview:clipView aboveSubview:listView];
		[clipView addSubview:scrollView];
		[scrollView addSubview:listView];
		objc_setAssociatedObject(dockView, kDRScrollKey, scrollView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(dockView, kDRClipKey, clipView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	} else if (listView.superview != scrollView) {
		// SpringBoard re-parented it (e.g. after a rebuild); adopt it again.
		intended = listView.frame;
		scrollView.listView = listView;
		[scrollView addSubview:listView];
	} else {
		CGRect f = listView.frame;
		BOOL isOurs = CGPointEqualToPoint(f.origin, CGPointZero) &&
			fabs(CGRectGetWidth(f) - DRListWidth(listView, CGRectGetWidth(scrollView.dockFrame))) < 0.5;
		// If SpringBoard assigned a fresh frame this pass, it is in dock coordinates.
		intended = isOurs ? scrollView.dockFrame : f;
	}

	CGFloat pageWidth = CGRectGetWidth(intended);
	CGFloat height = CGRectGetHeight(intended);
	if (pageWidth <= 0) return;

	CGFloat oldPageWidth = CGRectGetWidth(scrollView.bounds);
	gPageWidth = pageWidth;
	DRLayoutClip(dockView, clipView, scrollView, intended);
	if (gFreeMode) {
		[scrollView dr_setSlotCount:DRWantedSlotCount(listView) pitch:DRFreePitch(listView, pageWidth) animated:NO];
		if (fabs(oldPageWidth - pageWidth) > 0.5) scrollView.contentOffset = CGPointZero;
	} else {
		[scrollView dr_setPageCount:DRWantedPageCount(listView) animated:NO];
		if (fabs(oldPageWidth - pageWidth) > 0.5) {
			// Page width changed (first layout, rotation): stay on the same page.
			scrollView.contentOffset = CGPointMake(pageWidth * MIN(scrollView.currentPage, scrollView.pageCount - 1), 0);
		}
	}
	CGRect listFrame = CGRectMake(0, 0, DRListWidth(listView, pageWidth), height);
	if (!CGRectEqualToRect(listView.frame, listFrame)) listView.frame = listFrame;

	BOOL changed = NO;
	if (config) {
		DRMarkDockConfig(config);
		if (config.numberOfPortraitColumns != DR_MAX_ICONS) {
			config.numberOfPortraitColumns = DR_MAX_ICONS;
			changed = YES;
		}
		changed |= gFreeMode ? DRTuneFreeSpacing(listView, config, pageWidth) : DRTuneSpacing(listView, config, pageWidth);
	}
	if (changed && [listView respondsToSelector:@selector(layoutIconsNow)]) {
		[listView setNeedsLayout];
		[listView layoutIconsNow];
	}

#if DR_DEBUG
	static BOOL dumped = NO;
	if (!dumped) {
		dumped = YES;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			DRLog(@"scrollView frame=%@ contentSize=%@ offset=%@", NSStringFromCGRect(scrollView.frame),
				NSStringFromCGSize(scrollView.contentSize), NSStringFromCGPoint(scrollView.contentOffset));
			UIView *platter = DRPlatterView(dockView);
			DRLog(@"platter %@ frame=%@ inDock=%d radius=%.2f", NSStringFromClass([platter class]),
				NSStringFromCGRect(platter.frame), platter.superview == dockView, DRCornerRadius(platter, 3));
			DRLog(@"clipView frame=%@ radius=%.2f", NSStringFromCGRect(clipView.frame), clipView.layer.cornerRadius);
			DRDumpListView(listView, @"after setup (+3s)");
		});
	}
#endif
}

#pragma mark - Hooks

%hook SBHDefaultIconListLayoutProvider

- (id)makeLayoutForIconLocation:(NSString *)location {
	id layout = %orig;
	if ([location isEqualToString:kDRDockLocation] && [layout respondsToSelector:@selector(layoutConfiguration)]) {
		SBIconListGridLayoutConfiguration *config = [layout layoutConfiguration];
		DRMarkDockConfig(config);
		config.numberOfPortraitColumns = DR_MAX_ICONS;
		config.numberOfPortraitRows = 1;
	}
	return layout;
}

%end

// On 17.3 this is SBHIconListLayoutMaximumIconCount(dock layout); the layout
// hook above already raises it, this is a belt-and-braces fallback.
%hook SBHIconManager

- (unsigned long long)maxIconCountForDock {
	unsigned long long orig = %orig;
	return MAX(orig, (unsigned long long)DR_MAX_ICONS);
}

%end

%hook SBIconListGridLayoutConfiguration

- (NSUInteger)numberOfPortraitColumns {
	return DRIsDockConfig(self) ? DR_MAX_ICONS : %orig;
}

%end

%hook SBIconListModel

- (NSUInteger)maxNumberOfIcons {
	NSUInteger orig = %orig;
	return DRIsDockModel(self) ? MAX(orig, (NSUInteger)DR_MAX_ICONS) : orig;
}

- (SBHIconGridSize)gridSize {
	SBHIconGridSize size = %orig;
	if (DRIsDockModel(self)) size.columns = MAX(size.columns, (uint16_t)DR_MAX_ICONS);
	return size;
}

- (BOOL)isFull {
	if (DRIsDockModel(self)) return [self numberOfIcons] >= DR_MAX_ICONS;
	return %orig;
}

- (BOOL)allowsAddingIconCount:(NSUInteger)count {
	if (DRIsDockModel(self)) return [self numberOfIcons] + count <= DR_MAX_ICONS;
	return %orig;
}

%end

// Mode 2 centres only the *used* columns (e.g. 4 icons centred in the
// DR_MAX_PAGES-wide list). Any other non-zero mode centres all columns with the
// fixed spacing, which together with DRTuneSpacing gives a pitch of pageWidth / 4.
%hook SBDockIconListView

- (long long)layoutInsetsMode {
	long long mode = %orig;
	return mode == 2 ? 1 : mode;
}

// Pixel-exact stock placement: every page uses the stock 4-icon dock inset and
// spacing; page N is simply shifted right by N page widths. The uniform grid
// above stays in place for hit-testing and drop targeting.
- (CGPoint)originForIconAtCoordinate:(SBIconCoordinate)coordinate metrics:(SBIconListViewLayoutMetrics *)metrics options:(unsigned long long)options {
	CGPoint origin = %orig;
	CGFloat pageWidth = gFreeMode ? gPageWidth : CGRectGetWidth(self.bounds) / DR_MAX_PAGES;
	CGFloat iconWidth = [metrics respondsToSelector:@selector(iconSize)] ? metrics.iconSize.width : 0;
	if (gStockInset <= 0 || pageWidth <= 0 || iconWidth <= 0 || coordinate.col < 1) return origin;

	long long column = coordinate.col - 1;
	if (gFreeMode) {
		// 无极模式：所有图标等距排成一长条
		CGFloat x = gStockInset + column * (iconWidth + DRFreeSpacing(pageWidth, iconWidth));
		CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
		origin.x = round(x * scale) / scale;
		return origin;
	}
	long long page = column / DR_ICONS_PER_PAGE;
	long long slot = column % DR_ICONS_PER_PAGE;
	CGFloat spacing = (pageWidth - 2 * gStockInset - DR_ICONS_PER_PAGE * iconWidth) / (DR_ICONS_PER_PAGE - 1);
	CGFloat x = page * pageWidth + gStockInset + slot * (iconWidth + spacing);
	CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
	origin.x = round(x * scale) / scale;
	return origin;
}

- (void)setEditing:(BOOL)editing {
	%orig;
	DRUpdatePages(self, YES);
}

// Icons added / removed end up here; keep the page count in sync.
- (void)layoutSubviews {
	%orig;
	__weak SBIconListView *weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		DRUpdatePages(weakSelf, YES);
	});
}

// UIKit sends this for every drop interaction a drag visited, including
// cancelled drags that never exit or perform a drop.
- (void)dropInteraction:(UIDropInteraction *)interaction sessionDidEnd:(id<UIDropSession>)session {
	%orig;
#if DR_DEBUG
	DRLog(@"drop session ended");
#endif
	[DRScrollViewForList(self) dr_dragEnded];
}

%end

// SBRootFolderView (an SBFolderView) is the dock list's drag delegate.
%hook SBFolderView

- (id)iconListView:(SBIconListView *)listView iconDropSessionDidUpdate:(id)session {
	id result = %orig;
	DRDockScrollView *scrollView = DRScrollViewForList(listView);
#if DR_DEBUG
	static NSUInteger calls = 0;
	if (calls++ % 20 == 0) {
		DRLog(@"dropUpdate #%lu list=%@ dock=%d session=%@ loc=%@", (unsigned long)calls, NSStringFromClass([listView class]),
			scrollView != nil, NSStringFromClass([session class]),
			[session respondsToSelector:@selector(locationInView:)] && scrollView
				? NSStringFromCGPoint([session locationInView:scrollView.superview]) : @"-");
	}
#endif
	if (scrollView && [session respondsToSelector:@selector(locationInView:)]) {
		[scrollView dr_dragMovedToPoint:[session locationInView:scrollView.superview]];
	}
	return result;
}

- (void)iconListView:(SBIconListView *)listView iconDropSessionDidExit:(id)session {
	%orig;
	[DRScrollViewForList(listView) dr_dragEnded];
}

- (void)iconListView:(SBIconListView *)listView performIconDrop:(id)drop {
	%orig;
	[DRScrollViewForList(listView) dr_dragEnded];
}

%end

%hook SBDockView

- (void)layoutSubviews {
	%orig;
	DRSetupDock(self);
}

%end

// 设置页切换开关后发出此通知，SpringBoard 收到后自行重启
static void DRRespring(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	// 稍作延迟，让开关动画走完
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[[%c(FBSystemService) sharedInstance] exitAndRelaunch:YES];
	});
}

// 读取设置页里的总开关（默认开启）；关闭时不安装任何钩子，Dock 保持原样
%ctor {
	// 无论开关状态都要监听，否则关闭后无法通过开关重新启用
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, DRRespring,
		CFSTR("to.define.dockreel/respring"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

	Boolean valid = false;
	Boolean enabled = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), CFSTR("to.define.dockreel"), &valid);
	if (valid && !enabled) return;
	// 滚动模式：0 分页（默认），1 无极
	gFreeMode = CFPreferencesGetAppIntegerValue(CFSTR("ScrollMode"), CFSTR("to.define.dockreel"), NULL) == 1;
	%init;
}

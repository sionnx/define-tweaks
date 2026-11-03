// DockReel — runtime capability checks.

#import <objc/runtime.h>
#import "DRCompat.h"
#import "DockReel.h"

typedef NS_ENUM(NSInteger, DRSpacingAPI) {
	DRSpacingAPINone,
	DRSpacingAPILegacy,   // listSizeForIconSpacingCalculation (iOS 17.3)
	DRSpacingAPIPortrait, // portraitListSizeForIconSpacingCalculation (iOS 27.0.1)
};

static DRSpacingAPI gSpacingAPI = DRSpacingAPINone;

CGSize DRSpacingListSize(SBIconListGridLayoutConfiguration *config) {
	switch (gSpacingAPI) {
		case DRSpacingAPIPortrait: return config.portraitListSizeForIconSpacingCalculation;
		case DRSpacingAPILegacy: return config.listSizeForIconSpacingCalculation;
		default: return CGSizeZero;
	}
}

void DRSetSpacingListSize(SBIconListGridLayoutConfiguration *config, CGSize size) {
	switch (gSpacingAPI) {
		case DRSpacingAPIPortrait:
			config.portraitListSizeForIconSpacingCalculation = size;
			break;
		case DRSpacingAPILegacy:
			config.listSizeForIconSpacingCalculation = size;
			break;
		default:
			break;
	}
}

// Without any one of these the dock layout would break, so nothing gets hooked.
// Optional APIs (maxIconCountForDock, isFull, the drop exit / perform callbacks)
// only back up the core behaviour and are not listed.
static BOOL DRHasRequiredMethods(void) {
	static const struct {
		const char *className;
		const char *selectorName;
	} required[] = {
		{ "SBHDefaultIconListLayoutProvider", "makeLayoutForIconLocation:" },
		{ "SBIconListGridLayoutConfiguration", "numberOfPortraitColumns" },
		{ "SBIconListGridLayoutConfiguration", "setNumberOfPortraitColumns:" },
		{ "SBIconListGridLayoutConfiguration", "setNumberOfPortraitRows:" },
		{ "SBIconListGridLayoutConfiguration", "portraitLayoutInsets" },
		{ "SBIconListGridLayoutConfiguration", "iconImageInfo" },
		{ "SBIconListModel", "maxNumberOfIcons" },
		{ "SBIconListModel", "gridSize" },
		{ "SBIconListModel", "setGridSize:" },
		{ "SBDockIconListView", "originForIconAtCoordinate:metrics:options:" },
		{ "SBDockIconListView", "layoutInsetsMode" },
		{ "SBDockIconListView", "layoutIconsNow" },
		{ "SBDockIconListView", "setEditing:" },
		{ "SBDockView", "layoutSubviews" },
		{ "SBDockView", "dockListView" },
		{ "SBFolderView", "iconListView:iconDropSessionDidUpdate:" },
	};

	BOOL complete = YES;
	for (size_t i = 0; i < sizeof(required) / sizeof(required[0]); i++) {
		Class cls = objc_getClass(required[i].className);
		if ([cls instancesRespondToSelector:sel_registerName(required[i].selectorName)]) continue;
		complete = NO;
		XLog(@"Compat", @"compat: missing -[%s %s]", required[i].className, required[i].selectorName);
	}
	return complete;
}

BOOL DRCompatPrepare(void) {
	Class config = objc_getClass("SBIconListGridLayoutConfiguration");
	if ([config instancesRespondToSelector:@selector(setPortraitListSizeForIconSpacingCalculation:)]) {
		gSpacingAPI = DRSpacingAPIPortrait;
	} else if ([config instancesRespondToSelector:@selector(setListSizeForIconSpacingCalculation:)]) {
		gSpacingAPI = DRSpacingAPILegacy;
	}
	BOOL supported = DRHasRequiredMethods() && gSpacingAPI != DRSpacingAPINone;
	XLog(@"Compat", @"compat: %@ spacingAPI=%ld supported=%d", NSProcessInfo.processInfo.operatingSystemVersionString,
		(long)gSpacingAPI, supported);
	return supported;
}

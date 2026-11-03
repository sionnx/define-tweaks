// DockReel — debug dumps of the dock layout (only built when DR_DEBUG is 1).

#import "DockReel.h"

#if DR_DEBUG

static id DRValue(id obj, NSString *key) {
	@try {
		return [obj valueForKey:key];
	} @catch (__unused NSException *e) {
		return @"<n/a>";
	}
}

void DRDumpListView(UIView *listView, NSString *tag) {
	XLog(@"Dump", @"==== %@ ====", tag);
	XLog(@"Dump", @"listView %@ frame=%@ superview=%@ superframe=%@", NSStringFromClass([listView class]),
		NSStringFromCGRect(listView.frame), NSStringFromClass([listView.superview class]),
		NSStringFromCGRect(listView.superview.frame));
	for (NSString *key in @[ @"layoutInsetsMode", @"iconSpacing", @"effectiveIconSpacing",
		@"iconsInRowForSpacingCalculation", @"automaticallyAdjustsLayoutMetricsToFit", @"iconLocation" ]) {
		XLog(@"Dump", @"  %@ = %@", key, DRValue(listView, key));
	}
	id config = DRValue(DRValue(listView, @"layout"), @"layoutConfiguration");
	for (NSString *key in @[ @"numberOfPortraitColumns", @"numberOfPortraitRows", @"portraitLayoutInsets",
		@"listSizeForIconSpacingCalculation", @"portraitListSizeForIconSpacingCalculation" ]) {
		XLog(@"Dump", @"  config.%@ = %@", key, DRValue(config, key));
	}
	id metrics = DRValue(listView, @"layoutMetrics");
	for (NSString *key in @[ @"columns", @"rows", @"columnsUsedForLayout", @"rowsUsedForLayout", @"columnOffset",
		@"iconSpacing", @"iconSize", @"iconInsets", @"adjustedInsetsToFit" ]) {
		XLog(@"Dump", @"  metrics.%@ = %@", key, DRValue(metrics, key));
	}
	Class iconViewClass = NSClassFromString(@"SBIconView");
	for (UIView *v in listView.subviews) {
		if ([v isKindOfClass:iconViewClass]) {
			XLog(@"Dump", @"  icon %@ frame=%@", DRValue(DRValue(v, @"icon"), @"displayName"), NSStringFromCGRect(v.frame));
		}
	}
}

#endif

// DockReel — debug logging (only built when DR_DEBUG is 1).

#import "DockReel.h"

#if DR_DEBUG

void DRLog(NSString *format, ...) {
	va_list args;
	va_start(args, format);
	NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);
	NSString *path = @"/var/mobile/Library/Logs/DockReel.log";
	NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
	if (!fh) {
		[[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
		fh = [NSFileHandle fileHandleForWritingAtPath:path];
	}
	[fh seekToEndOfFile];
	[fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
	[fh closeFile];
}

static id DRValue(id obj, NSString *key) {
	@try {
		return [obj valueForKey:key];
	} @catch (__unused NSException *e) {
		return @"<n/a>";
	}
}

void DRDumpListView(UIView *listView, NSString *tag) {
	DRLog(@"==== %@ ====", tag);
	DRLog(@"listView %@ frame=%@ superview=%@ superframe=%@", NSStringFromClass([listView class]),
		NSStringFromCGRect(listView.frame), NSStringFromClass([listView.superview class]),
		NSStringFromCGRect(listView.superview.frame));
	for (NSString *key in @[ @"layoutInsetsMode", @"iconSpacing", @"effectiveIconSpacing",
		@"iconsInRowForSpacingCalculation", @"automaticallyAdjustsLayoutMetricsToFit", @"iconLocation" ]) {
		DRLog(@"  %@ = %@", key, DRValue(listView, key));
	}
	id config = DRValue(DRValue(listView, @"layout"), @"layoutConfiguration");
	for (NSString *key in @[ @"numberOfPortraitColumns", @"numberOfPortraitRows", @"portraitLayoutInsets",
		@"listSizeForIconSpacingCalculation" ]) {
		DRLog(@"  config.%@ = %@", key, DRValue(config, key));
	}
	id metrics = DRValue(listView, @"layoutMetrics");
	for (NSString *key in @[ @"columns", @"rows", @"columnsUsedForLayout", @"rowsUsedForLayout", @"columnOffset",
		@"iconSpacing", @"iconSize", @"iconInsets", @"adjustedInsetsToFit" ]) {
		DRLog(@"  metrics.%@ = %@", key, DRValue(metrics, key));
	}
	Class iconViewClass = NSClassFromString(@"SBIconView");
	for (UIView *v in listView.subviews) {
		if ([v isKindOfClass:iconViewClass]) {
			DRLog(@"  icon %@ frame=%@", DRValue(DRValue(v, @"icon"), @"displayName"), NSStringFromCGRect(v.frame));
		}
	}
}

#endif

// DockReel — shared configuration.

#import <UIKit/UIKit.h>

#define DR_ICONS_PER_PAGE 4
// SpringBoard needs a finite dock capacity; this is effectively "no limit".
#define DR_MAX_PAGES 50
#define DR_MAX_ICONS (DR_ICONS_PER_PAGE * DR_MAX_PAGES)

// Edge page-turn while dragging an icon: zone width (pt) inside the platter,
// delay before the first turn, and interval between further turns.
#define DR_EDGE_ZONE 40.0
#define DR_EDGE_FIRST_DELAY 0.5
#define DR_EDGE_REPEAT_DELAY 0.9

// Free scrolling mode: maximum auto-scroll speed (pt/s) when dragging an icon to the edge; faster closer to the edge
#define DR_FREE_EDGE_MAX_SPEED 600.0

// 1 writes /var/mobile/Library/Logs/DockReel.log (see DRDebug.m).
#define DR_DEBUG 1

#if DR_DEBUG
void DRLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void DRDumpListView(UIView *listView, NSString *tag);
#endif

#import <Foundation/Foundation.h>

/// Whether the current process is an application with PocketPad enabled.
BOOL PPShouldApply(void);

/// The hardware identifier reported by every hooked model API.
NSString *PPHardwareModel(void);

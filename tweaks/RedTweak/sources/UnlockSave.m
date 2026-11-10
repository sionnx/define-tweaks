// Lets the stock save button save any note, including notes whose author
// turned off downloads. The note's XYPHMediaSaveConfig decides whether saving
// is allowed through `disableSave`, which is pinned to NO.
//
// In Xiaohongshu 9.54 every image and video save entry point reads
// `disableSave` through objc_msgSend and shows the "Note_Save_Violation"
// prompt instead of saving when it is YES (static disassembly).

#import "RedTweak.h"
#import "RTHook.h"

void RTInstallUnlockSave(void)
{
    RTPinBoolProperty("XYPHMediaSaveConfig", "disableSave", NO);
}

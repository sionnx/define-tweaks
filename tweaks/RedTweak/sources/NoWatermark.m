// Removes the watermark from images and videos saved through Xiaohongshu's
// own save flow. Nothing else in the flow (permissions, the author's download
// switch, tracking) is touched; see UnlockSave.m for that.
//
// Analysed against Xiaohongshu 9.54 (static disassembly):
//
// - Every image and video save entry point reads the note's
//   XYPHMediaSaveConfig through objc_msgSend: `disableSave` first, then
//   `disableWatermark`. Pinning `disableWatermark` to YES covers both.
//
// - Images: the value is passed as the `disableWatermark:` argument of
//   ImageSaveService's save methods, which decides whether the watermark is
//   drawn on the device. Those methods are also hooked to force the argument,
//   in case a caller does not take it from the config.
//
// - Videos: each entry point creates an XYVFVideoDownloaderManager and copies
//   the config value straight into its `disableWatermark` ivar (no setter).
//   `download:noteId:videoDuration:` then reads the ivar directly: YES
//   downloads the video URL the caller passed in, NO asks the server for a
//   save URL (/api/sns/v10/note/video/save) instead. There is no watermark
//   compositing on the device, so the watermark comes with the server's URL.
//   When a note has no save config the ivar stays NO, so the download entry is
//   hooked to set it to YES through the setter (which writes the ivar) first.
//   That the caller's URL is the clean original is inferred, not verified.
//
// Every class or method that is missing is logged so a renamed one shows up
// in the log after an app update.

#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "RedTweak.h"
#import "RTHook.h"
#import "XLog.h"

#pragma mark - Images

// Swift class XYNoteModule.ImageSaveService, by its Objective-C runtime name.
static const char *const kRTImageSaveService = "_TtC12XYNoteModule16ImageSaveService";

typedef NS_ENUM(NSUInteger, RTSaveSelector) {
    RTSaveImageList,      // saveImageListFrom:disableWatermark:saveAllCompletion:
    RTSaveImageAt,        // saveImageAt:from:disableWatermark:completion:
    RTSaveImageNoTrack,   // saveImageWithoutManualTrackAt:from:disableWatermark:completion:
    RTSaveSelectorCount,
};

static IMP gImageOriginals[RTSaveSelectorCount];

static void RTSaveImageListHook(id self, SEL _cmd, id from, BOOL disableWatermark, id completion)
{
    XLog(@"Save", @"%s disableWatermark %d -> 1", sel_getName(_cmd), disableWatermark);
    ((void (*)(id, SEL, id, BOOL, id))gImageOriginals[RTSaveImageList])(self, _cmd, from, YES, completion);
}

static void RTSaveImageAtHook(id self, SEL _cmd, NSInteger at, id from, BOOL disableWatermark, id completion)
{
    XLog(@"Save", @"%s disableWatermark %d -> 1", sel_getName(_cmd), disableWatermark);
    ((void (*)(id, SEL, NSInteger, id, BOOL, id))gImageOriginals[RTSaveImageAt])(self, _cmd, at, from, YES, completion);
}

static void RTSaveImageNoTrackHook(id self, SEL _cmd, NSInteger at, id from, BOOL disableWatermark, id completion)
{
    XLog(@"Save", @"%s disableWatermark %d -> 1", sel_getName(_cmd), disableWatermark);
    ((void (*)(id, SEL, NSInteger, id, BOOL, id))gImageOriginals[RTSaveImageNoTrack])(self, _cmd, at, from, YES, completion);
}

static const struct {
    const char *name;
    const char *types;   // expected encoding: the BOOL argument must be where the hook expects it
    IMP hook;
} kRTImageSelectors[RTSaveSelectorCount] = {
    [RTSaveImageList]    = { "saveImageListFrom:disableWatermark:saveAllCompletion:",           "v@:@B@",  (IMP)RTSaveImageListHook },
    [RTSaveImageAt]      = { "saveImageAt:from:disableWatermark:completion:",                   "v@:q@B@", (IMP)RTSaveImageAtHook },
    [RTSaveImageNoTrack] = { "saveImageWithoutManualTrackAt:from:disableWatermark:completion:", "v@:q@B@", (IMP)RTSaveImageNoTrackHook },
};

static void RTInstallImageHooks(void)
{
    Class cls = objc_getClass(kRTImageSaveService);
    if (!cls) {
        XLog(@"NoWatermark", @"class %s not found", kRTImageSaveService);
        return;
    }

    unsigned hooked = 0;
    for (RTSaveSelector s = 0; s < RTSaveSelectorCount; s++) {
        SEL sel = sel_registerName(kRTImageSelectors[s].name);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            XLog(@"NoWatermark", @"%s has no -%s", kRTImageSaveService, kRTImageSelectors[s].name);
            continue;
        }
        const char *types = method_getTypeEncoding(m);
        if (!RTTypesMatch(types, kRTImageSelectors[s].types)) {
            XLog(@"NoWatermark", @"%s -%s has types %s, skipped", kRTImageSaveService, kRTImageSelectors[s].name, types);
            continue;
        }
        MSHookMessageEx(cls, sel, kRTImageSelectors[s].hook, &gImageOriginals[s]);
        hooked++;
    }
    XLog(@"NoWatermark", @"hooked %u image save methods", hooked);
}

#pragma mark - Videos

static void (*gOrigVideoDownload)(id, SEL, id, id, long long);

static void RTVideoDownloadHook(id self, SEL _cmd, id url, id noteId, long long duration)
{
    XLog(@"Video", @"download noteId=%@, forcing disableWatermark", noteId);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setDisableWatermark:), YES);
    gOrigVideoDownload(self, _cmd, url, noteId, duration);
}

static void RTInstallVideoHook(void)
{
    const char *className = "XYVFVideoDownloaderManager";
    Class cls = objc_getClass(className);
    if (!cls) {
        XLog(@"NoWatermark", @"class %s not found", className);
        return;
    }

    // The hook writes the ivar through the setter, so both must be there.
    Method setter = class_getInstanceMethod(cls, @selector(setDisableWatermark:));
    if (!setter || !RTTypesMatch(method_getTypeEncoding(setter), "v@:B")) {
        XLog(@"NoWatermark", @"%s -setDisableWatermark: missing or changed, video hook skipped", className);
        return;
    }

    SEL sel = sel_registerName("download:noteId:videoDuration:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || !RTTypesMatch(method_getTypeEncoding(m), "v@:@@q")) {
        XLog(@"NoWatermark", @"%s -%s missing or changed (types %s), video hook skipped",
             className, sel_getName(sel), m ? method_getTypeEncoding(m) : "none");
        return;
    }
    MSHookMessageEx(cls, sel, (IMP)RTVideoDownloadHook, (IMP *)&gOrigVideoDownload);
    XLog(@"NoWatermark", @"hooked %s -%s", className, sel_getName(sel));
}

#pragma mark -

void RTInstallNoWatermark(void)
{
    RTPinBoolProperty("XYPHMediaSaveConfig", "disableWatermark", YES);
    RTInstallImageHooks();
    RTInstallVideoHook();
}

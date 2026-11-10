// Hooking helpers shared by RedTweak's features.

#import <objc/runtime.h>
#import <substrate.h>
#import "RTHook.h"
#import "XLog.h"

BOOL RTTypesMatch(const char *actual, const char *expected)
{
    if (!actual) return NO;
    const char *a = actual;
    for (const char *e = expected; *e; e++) {
        while (*a >= '0' && *a <= '9') a++;
        if (*a != *e && !(*e == 'B' && *a == 'c')) return NO;
        a++;
        if (*e == '@' && *a == '?') a++;
    }
    while (*a >= '0' && *a <= '9') a++;
    return *a == '\0';
}

/// "disableSave" -> "setDisableSave:"
static SEL RTSetterForGetter(const char *getterName)
{
    NSString *name = @(getterName);
    NSString *setter = [NSString stringWithFormat:@"set%@%@:",
                        [name substringToIndex:1].uppercaseString, [name substringFromIndex:1]];
    return NSSelectorFromString(setter);
}

BOOL RTPinBoolProperty(const char *className, const char *getterName, BOOL value)
{
    Class cls = objc_getClass(className);
    if (!cls) {
        XLog(@"Hook", @"class %s not found", className);
        return NO;
    }

    BOOL hooked = NO;
    SEL getter = sel_registerName(getterName);
    Method getM = class_getInstanceMethod(cls, getter);
    if (!getM) {
        XLog(@"Hook", @"%s has no -%s", className, getterName);
    } else if (!RTTypesMatch(method_getTypeEncoding(getM), "B@:")) {
        XLog(@"Hook", @"%s -%s has types %s, skipped", className, getterName, method_getTypeEncoding(getM));
    } else {
        IMP imp = imp_implementationWithBlock(^BOOL(__unused id self) { return value; });
        MSHookMessageEx(cls, getter, imp, NULL);
        hooked = YES;
    }

    SEL setter = RTSetterForGetter(getterName);
    Method setM = class_getInstanceMethod(cls, setter);
    if (!setM) {
        XLog(@"Hook", @"%s has no -%s", className, sel_getName(setter));
    } else if (!RTTypesMatch(method_getTypeEncoding(setM), "v@:B")) {
        XLog(@"Hook", @"%s -%s has types %s, skipped", className, sel_getName(setter), method_getTypeEncoding(setM));
    } else {
        // The original is filled in by MSHookMessageEx before any call can
        // reach the block, which reads it through this heap slot.
        IMP *orig = calloc(1, sizeof(IMP));
        IMP imp = imp_implementationWithBlock(^(id self, __unused BOOL passed) {
            ((void (*)(id, SEL, BOOL))*orig)(self, setter, value);
        });
        MSHookMessageEx(cls, setter, imp, orig);
    }

    XLog(@"Hook", @"%s -%s pinned to %d: %s", className, getterName, value, hooked ? "ok" : "failed");
    return hooked;
}

//
//  XPrefs.m
//

#import "XPrefs.h"
#import "XLog.h"

#import <roothide.h>

static NSDictionary<NSString *, id> *XPrefsLoadFromCFPreferences(NSString *domain)
{
    CFStringRef application = (__bridge CFStringRef)domain;
    CFArrayRef keys = CFPreferencesCopyKeyList(application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!keys) {
        return nil;
    }
    CFDictionaryRef values = CFArrayGetCount(keys) > 0
        ? CFPreferencesCopyMultiple(keys, application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        : NULL;
    CFRelease(keys);
    NSDictionary *result = (__bridge_transfer NSDictionary *)values;
    return result.count > 0 ? result : nil;
}

static NSDictionary<NSString *, id> *XPrefsLoadFromFile(NSString *domain)
{
    NSString *relative = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", domain];
    NSURL *url = [NSURL fileURLWithPath:jbroot(relative)];
    NSError *error = nil;
    NSDictionary *result = [NSDictionary dictionaryWithContentsOfURL:url error:&error];
    if (!result) {
        XLog(@"Prefs", @"%@ file read failed path=%@ error=%@", domain, url.path, error);
    }
    return result;
}

NSDictionary<NSString *, id> *XPrefsLoad(NSString *domain)
{
    NSDictionary *prefs = XPrefsLoadFromCFPreferences(domain);
    if (prefs) {
        XLog(@"Prefs", @"%@ source=cfprefs keys=%lu", domain, (unsigned long)prefs.count);
        return prefs;
    }
    prefs = XPrefsLoadFromFile(domain);
    XLog(@"Prefs", @"%@ source=%@ keys=%lu", domain, prefs ? @"file" : @"none",
         (unsigned long)prefs.count);
    return prefs ?: @{};
}

BOOL XPrefsBool(NSDictionary<NSString *, id> *prefs, NSString *key, BOOL fallback)
{
    id value = prefs[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    return fallback;
}

//
//  XPrefs.h
//  Preference reading shared by all tweaks. Include XPrefs.mk from the
//  tweak's Makefile, after XLog.mk.
//
//  NSDictionary *prefs = XPrefsLoad(@"to.define.example");
//  BOOL enabled = XPrefsBool(prefs, @"Enabled", YES);
//
//  The settings pane writes the domain through cfprefsd, which RootHide
//  redirects to <jbroot>/var/mobile/Library/Preferences/<domain>.plist.
//  Unsandboxed processes such as SpringBoard read it back through
//  CFPreferences. A sandboxed application's CFPreferences request resolves to
//  its own data container instead, so XPrefsLoad falls back to reading the
//  plist file from the jbroot directly.
//

#import <Foundation/Foundation.h>

/// Every key of the domain, read once. Never nil; empty when nothing is stored
/// or the domain cannot be read. Callers keep the result for as long as the
/// values may stay unchanged.
__attribute__((visibility("hidden")))
NSDictionary<NSString *, id> *XPrefsLoad(NSString *domain);

/// The boolean stored under key, or fallback when the key is missing or holds
/// something other than a boolean or a number.
__attribute__((visibility("hidden")))
BOOL XPrefsBool(NSDictionary<NSString *, id> *prefs, NSString *key, BOOL fallback);

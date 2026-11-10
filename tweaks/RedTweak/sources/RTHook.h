#import <Foundation/Foundation.h>

/// Compares a method's type encoding with the expected one, ignoring frame
/// offsets. `@?` (block) matches `@`, and `c` matches `B` (both are BOOL).
BOOL RTTypesMatch(const char *actual, const char *expected);

/// Pins a BOOL property of an Objective-C class to `value`: the getter always
/// returns it, and the setter (`set<Name>:`) stores it whatever it is passed.
/// Code that writes the ivar directly bypasses both. Missing classes and
/// methods are logged. Returns whether the getter was hooked.
BOOL RTPinBoolProperty(const char *className, const char *getterName, BOOL value);

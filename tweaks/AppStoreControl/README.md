# AppStoreControl

A Theos hook tweak for iOS 15+ that brings AppStore++ style downgrades to the
App Store itself. Injected into `com.apple.AppStore`, it lists the builds Apple
still serves for an app and asks appstored to install the one you pick.

## Usage

1. Open the App Store and find an app (product page, search result, Updates).
2. **Long-press the Get / Update / Open button.**
   - The tweak resolves the app and shows a version chooser. Cached builds appear
     first, then the list updates from the store.
3. Pick a version. The store downloads Apple's signed package for that build and
   installs it in place, keeping app data.

Long-pressing the **account button** opens a menu with the manual app picker
(choose any installed App Store app), cache clearing and the tweak log.

## Building

Tweaks in this repository are built with
[roothide/theos](https://github.com/roothide/theos) at `~/theos-roothide` with
the iPhoneOS 16.5 SDK:

```bash
make -C tweaks/AppStoreControl package FINALPACKAGE=1
```

The package is written to `tweaks/AppStoreControl/packages/`.

The injection filter (`AppStoreControl.plist`) **must stay world-readable**: ElleKit
reads it as the target app's user, and a `600` file makes the tweak silently skip
injection into the App Store. The Makefile enforces `644` at package time.

## Limitations

* Version history is only available for installed apps: for an app that is not
  installed, the store answers with the current build whichever one is requested,
  so the tweak sends no lookup request.
* Apple sometimes replaces a requested build with a compatible one; the tweak
  detects this (returned external version identifier differs) and reports it.
* Version lookup stops at an authorization it cannot follow; cached builds stay
  listed.
* Only the first 60 unresolved builds are requested per session (the store rate
  limits bursts).
* The version chooser is anchored on the App Store's own buttons. The product
  page itself is Swift-only, so there is no page-level hook.
* Requires the device to be signed in to the Store for the App Store process.

## Tested on

iPhone 15 Plus (iPhone15,5), iOS 17.3 (21D50), Dopamine RootHide 3, ElleKit.

# PocketPad

PocketPad reports an iPhone as `iPad19,2` through device APIs that the target
application is known to call. The tweak has no hooks on application classes.

## Hooked APIs

- `-[UIDevice model]`
- `-[UIDevice localizedModel]`
- `-[UIDevice userInterfaceIdiom]`
- `-[UITraitCollection userInterfaceIdiom]`
- `sysctl(CTL_HW, HW_MACHINE/HW_MODEL)`
- `sysctlbyname("hw.machine")`
- `sysctlbyname("hw.model")`
- `uname().machine`
- MobileGestalt `MGCopyAnswer`
- MobileGestalt `MGGetStringAnswer`
- MobileGestalt `MGGetSInt32Answer`

MobileGestalt string queries map `ProductType`, `HWModelStr`, and `ProductName`
to `iPad19,2`, and `DeviceClass` to `iPad`. The integer query
`DeviceClassNumber` maps to `3`, the MobileGestalt iPad device class.

Each hooked device query is appended to `Library/Logs/PocketPad.log` in the
host application's home directory. Release builds keep logging enabled so the
log remains available after the tweak is installed from the package.

Device identifiers, screen dimensions, system version, camera capabilities,
and network state remain unchanged.

## Configuration

Open Settings > PocketPad. Every user-installed application has an independent
switch and starts disabled. Enable only the applications that should report
`iPad19,2`, then relaunch those applications. Each preference is stored as a
top-level boolean key named `Enabled-<bundle identifier>` in the
`to.define.pocketpad` domain. The tweak reads it through
[shared/XPrefs](../../shared/XPrefs), which falls back to the jbroot plist file
because CFPreferences in a sandboxed application cannot see the domain.

## Build

```bash
make -C tweaks/PocketPad package FINALPACKAGE=1
```

The package is written to `tweaks/PocketPad/packages/`.

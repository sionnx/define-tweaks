# define-tweaks

Open-source jailbreak tweaks, and the source code of the [apt.define.to](https://apt.define.to) repo that distributes them.

Tweaks target **iOS 17.3** with [Dopamine-roothide](https://github.com/roothide/Dopamine-roothide).

## Install

Add the repo to Sileo or Zebra:

```
https://apt.define.to/
```

Or open [apt.define.to](https://apt.define.to) on your device and tap **Add to Sileo** / **Add to Zebra**.

## Tweaks

| Tweak | Description |
|---|---|
| [DockReel](tweaks/DockReel) | Scrollable dock with more than 4 icons, in paged or free scrolling mode. |

## Repository layout

```
tweaks/      Theos tweak projects, one directory per tweak
depot/       apt.define.to: Cloudflare Worker + R2 + Durable Objects (Hono)
scripts/     Publishing helper shared by CI and local use
docs/        Guides, e.g. how to release a tweak
.github/     CI: build tweaks, publish on tags, test depot
```

Each tweak follows the same layout. Directory names are lowercase, matching the directories Theos requires (`layout/`, `packages/`):

```
tweaks/DockReel/
├── Makefile
├── control
├── DockReel.plist   Injection filter, must stay next to the Makefile
├── sources/         All tweak code (.x, .m, .h)
└── prefs/           Settings pane (Theos subproject)
```

## Building a tweak

Tweaks are built with [roothide/theos](https://github.com/roothide/theos), installed at `~/theos-roothide` with the iPhoneOS 16.5 SDK.

```bash
make -C tweaks/DockReel package FINALPACKAGE=1
```

The package is written to `tweaks/DockReel/packages/`.

## Releasing

Pushing a `<tweak>@<version>` tag (e.g. `dockreel@0.2.0`) builds the tweak on GitHub Actions and publishes it to apt.define.to through GitHub OIDC. See [docs/release-tweaks.md](docs/release-tweaks.md) for the full checklist.

## depot

`depot/` is the APT repo service behind apt.define.to. It parses uploaded debs, keeps package metadata in a Durable Object, and regenerates `Packages`, `Release` and Sileo depictions on every publish.

```bash
pnpm install
```

```bash
pnpm -C depot test
```

```bash
pnpm -C depot dev
```

Changes to `depot/` on `main` are deployed automatically by Cloudflare Workers Builds.

## License

[GPL-3.0](LICENSE)

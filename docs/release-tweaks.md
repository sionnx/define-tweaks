# Releasing a Tweak

Tweaks are published to [apt.define.to](https://apt.define.to) by pushing a git tag. The `Tweaks` workflow (`.github/workflows/tweaks.yml`) builds the tweak on GitHub Actions and publishes it to the depot via GitHub OIDC — no secrets involved.

A pushed tag goes straight to users, and a published version can never be overwritten. Go through every step below.

> **For agents:** never push a release tag or publish a package on your own. Before pushing, show the user the tweak, the version, the changelog and the result of each pre-release check, and wait for explicit confirmation.

## 1. Pre-release checks

Run these from the repository root. The examples use DockReel; replace the directory, package id and version as needed.

- [ ] **Bump `Version` in the tweak's `control`.** Follow semantic versioning:
  - bug fix → patch (`0.1.0` → `0.1.1`)
  - new feature → minor (`0.1.0` → `0.2.0`)
  - breaking change → major

  Never use a debug version such as `0.1.0-1+debug`; the depot rejects them.

- [ ] **The new version is higher than every published version.** List what is already published:

  ```bash
  curl -s https://apt.define.to/api/v1/packages/to.define.dockreel | jq -r '.versions[] | "\(.version)\(if .yanked then " (yanked)" else "" end)"'
  ```

  Yanked versions still count: their files stay in the repo, so the same version cannot be reused.

- [ ] **Build a release package locally:**

  ```bash
  make -C tweaks/DockReel clean package FINALPACKAGE=1
  ```

  The output in `tweaks/DockReel/packages/` must be named `<package>_<version>_iphoneos-arm64e.deb` with exactly the new version.

- [ ] **Test on a real device** (iOS 17.3, Dopamine roothide): install the package, respring, and exercise both the tweak and its settings pane.

- [ ] **Commit and push the version bump to `main`.** The working tree must be clean, and `main` must contain the commit you are about to tag.

## 2. Tag and publish

The tag format is `<tweak>@<version>`:

- `<tweak>` is the tweak's directory name under `tweaks/`, lowercased (`DockReel` → `dockreel`).
- `<version>` must match `Version` in `control` exactly. CI fails the release before building if it does not.

Always use an **annotated** tag. Its message becomes the changelog shown on the Changelog tab in Sileo. Start with a one-line summary, then list the changes:

```bash
git tag -a dockreel@0.2.0 -m "Add free scrolling mode

- Free scrolling as an alternative to paging
- Fix icon spacing on iPhone Plus models"
```

```bash
git push origin dockreel@0.2.0
```

Then watch the `Tweaks` workflow run on GitHub Actions and make sure the `release` job succeeds:

```bash
gh run list --workflow Tweaks --limit 1
```

## 3. Verify the release

- [ ] The new version appears in the repo index:

  ```bash
  curl -s https://apt.define.to/Packages | awk -v RS= '/^Package: to\.define\.dockreel\n/' | grep '^Version:'
  ```

- [ ] In Sileo, refresh sources: the update shows up, installs, and works.
- [ ] If the release was tested on a different iOS version, update the "Tested on" row of the depiction (no new release needed):

  ```bash
  curl -X PATCH https://apt.define.to/api/v1/packages/to.define.dockreel/meta \
    -H "Authorization: Bearer $(security find-generic-password -s apt.define.to -a ADMIN_TOKEN -w)" \
    -H "Content-Type: application/json" \
    -d '{"testedOn": "iOS 17.3"}'
  ```

## 4. When something goes wrong

**The release job fails at "Resolve tweak from tag" with `Tag version … does not match … in tweaks/<Tweak>/control`.** The tag was pushed before `control` was updated, or `<version>` in the tag has a typo. (`Tweak directory not found` at the same step means `<tweak>` in the tag is misspelled.) Delete the tag locally and on GitHub, fix and push `control`, then tag again:

```bash
git tag -d dockreel@0.2.0
```

```bash
git push origin :refs/tags/dockreel@0.2.0
```

**The publish step returns 409 (version already exists).** This version was already published with different content. Bump the version and release again. Do not use `force` to overwrite a published version: clients that already downloaded it would get hash mismatches.

**A broken version was published.** Prefer shipping a fixed version quickly. If the version must be pulled immediately, yank it so it disappears from the index (the file is kept and the version stays reserved):

```bash
curl -X DELETE https://apt.define.to/api/v1/packages/to.define.dockreel/0.2.0 \
  -H "Authorization: Bearer $(security find-generic-password -s apt.define.to -a ADMIN_TOKEN -w)"
```

## Publishing manually

If GitHub Actions is unavailable, the same script CI uses can publish from your machine with the admin token.

> **For agents:** manual publishing is a fallback, not an alternative path. Never switch to it on your own when CI fails. Explain why the release cannot go through CI, ask the user whether to publish manually, and run the script only after the user explicitly approves.

```bash
DEPOT_TOKEN=$(security find-generic-password -s apt.define.to -a ADMIN_TOKEN -w) scripts/publish.sh tweaks/DockReel/packages/to.define.dockreel_0.2.0_iphoneos-arm64e.deb "Add free scrolling mode"
```

Still tag the release afterwards so the git history matches what was published.

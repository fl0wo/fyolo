# Releasing Fyolo

Fyolo ships as an ad-hoc-signed `.dmg` attached to a **GitHub Release**, with a
**Homebrew cask** in [`fl0wo/homebrew-tap`](https://github.com/fl0wo/homebrew-tap)
pointed at it. Cutting a release is one command — push a version tag:

```sh
git tag v0.4.0
git push origin v0.4.0
```

That fires `.github/workflows/release.yml`, which builds the app, packages the
DMG, writes `latest.json`, publishes both on a GitHub Release, and bumps the cask.

## How versioning works

- **The git tag is the version.** `v0.4.0` → `CFBundleShortVersionString = 0.4.0`.
  Nothing in the repo needs editing to ship.
- **The build number is the commit count** (`git rev-list --count HEAD`), stamped
  into `CFBundleVersion`. It only ever increases; don't squash history in a way
  that lowers it.

## How installs and updates work

- **Install:** `brew tap fl0wo/tap && brew install --cask fl0wo/tap/fyolo`, or the
  DMG from the release page. The app is not notarized; the cask clears the
  quarantine flag so Gatekeeper opens it.
- **Learning about a release:** the app reads
  `https://github.com/fl0wo/fyolo/releases/latest/download/latest.json` about ten
  seconds after launch, every twelve hours, and from **Check for Updates…**
  (`Sources/fyolo/App/UpdateCheck.swift`). GitHub redirects that URL to the newest
  published release — no server, no API rate limit. Dev builds never check;
  `FYOLO_UPDATE_MANIFEST=<url>` points any build at another manifest (a `file://`
  URL works) to exercise the update UI.
- **`latest.json`** is written by `scripts/release-manifest.sh`:

  ```json
  { "version": "0.4.0", "minimum_version": "0.0.0", "notes_url": "…",
    "dmg_url": "…/v0.4.0/fyolo.dmg", "sha256": "…", "cask": "fl0wo/tap/fyolo" }
  ```

- **Suggested vs required.** Running below `version` offers the update in the
  sidebar (Update, Later, Skip This Version). Running below `minimum_version`
  puts a sheet over the window that only updating or quitting dismisses —
  sessions live in fyolod, so quitting costs nothing.
- **What sets `minimum_version`:** the higher of `<major>.0.0` (a new major
  release requires everyone to move to it) and `packaging/minimum-version`.
  Raise that file, in the same commit as the fix, only when a release must stop
  being used — a broken build, a protocol change older clients cannot speak. The
  script refuses a floor above the version being released, and the app ignores
  one that got out anyway, so bad data can never block every install.
- **How the update is applied:** a Homebrew install runs
  `brew upgrade --cask fl0wo/tap/fyolo`; any other install downloads the DMG,
  checks it against `sha256`, and opens it to be dragged into Applications.
  Either way the app offers **Relaunch** once the newer copy is on disk.
- A release before 0.4.0 has no update check and has to be updated once by hand.

## One-time setup

- **`TAP_DEPLOY_KEY`** — a write deploy key on `fl0wo/homebrew-tap`, so the
  workflow can push the cask bump. Without it the release still publishes and
  the cask step is skipped:

  ```sh
  ssh-keygen -t ed25519 -N '' -f tap_deploy_key
  gh repo deploy-key add tap_deploy_key.pub -R fl0wo/homebrew-tap --allow-write -t release
  gh secret set TAP_DEPLOY_KEY < tap_deploy_key
  rm tap_deploy_key tap_deploy_key.pub
  ```

## Local builds

`./scripts/build-app.sh` produces an ad-hoc-signed `fyolo.app`. To stamp a
release-style version locally:

```sh
FYOLO_VERSION=0.4.0 FYOLO_BUILD=$(git rev-list --count HEAD) ./scripts/build-app.sh
```

## Checklist for a release

1. Land all changes on `main`; add the version to `web/landing/src/data/changelog.ts`.
2. If this release must retire older ones, raise `packaging/minimum-version`.
3. `git tag v0.4.0 && git push origin v0.4.0`.
4. Watch the **Release** workflow; the release page should carry `fyolo.dmg` and
   `latest.json`.
5. `curl -sL https://github.com/fl0wo/fyolo/releases/latest/download/latest.json`
   should print the new version.

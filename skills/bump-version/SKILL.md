---
name: bump-version
description: "Cut a new fyolo macOS release by tagging main with the next version. Invoke when the user says 'bump version', 'bump the version', 'cut a release', 'ship a new version', 'release', '发版', '发布新版本', or '出个新版本'."
---

# Bump version — cut a fyolo release

fyolo is **trunk-based**: a release is nothing but a `vX.Y.Z` tag on `main`.
Pushing the tag fires `.github/workflows/release.yml` (the **Release** workflow),
which packages the DMG, writes the `latest.json` installed apps check for
updates, publishes both on a GitHub Release, and bumps the Homebrew cask. There
is no merge and no release branch.

Follow these steps in order. Stop and report if any precondition fails — never
force past a failed check.

## 1. Preconditions

```sh
git switch main
git pull --ff-only
git status --short          # release-relevant work must be committed
git rev-parse --abbrev-ref HEAD    # must print: main
```

- Must be on `main` and even with `origin/main` (the tag ships whatever `main`
  points at right now).
- The working tree may have unrelated untracked scratch files, but anything
  meant for this release must already be committed and pushed.

## 2. Pick the next version

Read the current version and compute the next one:

```sh
git tag --list 'v*' --sort=-v:refname | head -1     # e.g. v0.13.1
```

Decide `X.Y.Z` (semver, no `v` when talking, `v` in the tag):

- Explicit version from the user (e.g. "0.14.0") → use it verbatim.
- A bump keyword → apply it to the latest tag: `patch` (`0.13.1`→`0.13.2`),
  `minor` (`0.13.1`→`0.14.0`), `major` (`0.13.1`→`1.0.0`).
- Nothing specified → propose the bump you believe fits (fyolo has used `minor`
  for features, `patch` for fixes) and confirm the number with the user before
  tagging.

**The version must only ever go up** — installed apps compare it to decide
there is an update, and the build number (`git rev-list --count HEAD`) must
only increase. Never reuse or lower a version.

**Does this release retire older ones?** A new major (`1.0.0`) requires every
older install to update on its own. Short of that, raise
`packaging/minimum-version` — in a commit on `main`, before tagging — only when
older versions must stop being used (a broken build, a protocol change they
cannot speak). Ask the user; never raise it on your own.

## 3. Write the changelog entry

The site's changelog is `web/landing/src/data/changelog.ts`, newest entry first.
Add the entry for the version you are about to tag **before** tagging — the
`Docs` workflow fails once a tag exists without one, and a changelog that trails
the releases makes the site read as abandoned.

```sh
gh release view "v$PREVIOUS" --json body -q .body     # what shipped since
```

Write it in the file's voice: a `title` naming what the release is remembered
for, then short user-facing `new` / `improved` / `fixed` lines — what changed,
not how. Skip a release whose only changes were docs, deps, or the landing page.

```sh
cd web/landing && pnpm docs:check     # must pass before you tag
```

## 4. Tag and push

```sh
V=0.14.0                       # the version you settled on
git tag "v$V"
git push origin "v$V"
```

That push is what triggers the release. Nothing else in the repo needs editing —
the tag *is* the version.

## 5. Watch the Release workflow

```sh
gh run watch --repo fl0wo/fyolo \
  "$(gh run list --repo fl0wo/fyolo -w Release -L1 --json databaseId -q '.[0].databaseId')"
```

Report green/red to the user. If it fails, diagnose from the run log.

## 6. Verify (when green)

```sh
V=0.14.0
gh release view "v$V" --repo fl0wo/fyolo --json assets -q '.assets[].name'   # fyolo.dmg, latest.json
curl -sL https://github.com/fl0wo/fyolo/releases/latest/download/latest.json  # "version": "$V"
```

`latest.json` is what installed apps read; if it does not name the new
version, nobody is offered the update.

## Re-running a failed release

If the build failed for an infrastructure reason (a secret, a flaky runner) and
`main` is unchanged, delete and re-push the **same** tag — the version must not
go backwards:

```sh
git push --delete origin "v$V" && git tag -d "v$V"
git tag "v$V" && git push origin "v$V"
```

If code had to change to fix it, that's a new commit on `main`, so cut the
**next** version instead of reusing the tag.

## Notes

- iOS releases are separate (`.github/workflows/ios.yml` + TestFlight); this
  skill is the macOS tag flow only.
- This skill does not commit anything. Land the release's code on `main` first
  (directly or via a merged PR), then run this.

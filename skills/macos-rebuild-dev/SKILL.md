---
name: macos-rebuild-dev
description: "Kill the running fyolo dev app, rebuild it with SwiftPM, and relaunch it as a foreground app. Invoke when the user says 'rebuild', 'rebuild app', 'restart app', 'relaunch', '重新编译', or '重启 app'."
---

# Rebuild App (local development)

Kill the running **dev** build, rebuild it as the isolated `fyolo-dev.app` bundle,
and relaunch — so every rebuild reflects the current Dock icon and, crucially, does
**not** disturb an installed release build you use daily.

## The dev channel

fyolo ships a `FYOLO_CHANNEL=dev` build that is a fully separate app from the
release one, so both can run at the same time:

| | release | dev (this skill) |
| --- | --- | --- |
| Bundle | `fyolo.app` (usually `/Applications`) | `fyolo-dev.app` (repo root) |
| Bundle id | `sh.fyolo.app` | `sh.fyolo.app.dev` |
| State + sockets | `~/Library/Application Support/fyolo` | `…/fyolo-dev` |
| User config | `~/.fyolo` | `~/.fyolo-dev` |
| Daemon socket | `$TMPDIR/fyolod-<uid>` | `…-dev` |
| Daemon launchd job | `sh.fyolo.fyolod` | `sh.fyolo.fyolod.dev` |
| Companion port | 8787 | 8788 |
| CLI on PATH | `fyolo` | `fyolo-dev` |
| Update check | on | **off** (dev never offers to replace itself) |

All of this falls out of the `.dev` bundle-id suffix via `Sources/fyolo/Companion/AppChannel.swift`
(paths + port, and `UpdateChecker`'s off switch) and `scripts/build-app.sh` (id, name,
CLI rebind). `FYOLO_UPDATE_MANIFEST=<url>` (passed with `open --env`) turns the check
on against a manifest of your own, to exercise the update UI.

fyolo is a plain SwiftPM executable (`Package.swift` → `executableTarget` named
`fyolo`); `swift build` alone produces a bare binary with **no Dock icon**. So this
skill builds the real bundle via `scripts/build-app.sh`. For a dev build the script
auto-picks a real codesigning identity from **your own** keychain (any "Apple
Development" / "Developer ID Application" cert — a free Apple ID gives you one) so the
dev app can post macOS notifications; `usernoted` rejects an ad-hoc signature outright,
so an unsigned dev build can **never** banner. A contributor with **no** signing cert
falls back to ad-hoc automatically — the build still succeeds, they just don't get
notifications. Set `SIGN_IDENTITY=…` to force a specific one. The app runs
unsandboxed with `.exec` PTYs — see `CLAUDE.md`. The icon is `packaging/icon-static.svg`,
rasterized to `packaging/AppIcon.png` by `scripts/render-icon.sh` (needs headless
Chrome). The dev bundle takes `packaging/AppIcon-dev.png` instead, the same mark
inverted (a black F on purple), so the two apps stay apart in the Dock.

## Instructions

When invoked, execute these steps sequentially:

1. **Kill only the running dev app + its tunnel.** Both channels' inner binary is
   named `fyolo` (`CFBundleExecutable`), so `pkill -x fyolo` would kill the release
   app too. Match the dev bundle **path** instead. SIGKILL skips the app's
   `willTerminate` cleanup, so also reap the companion tunnel it spawned on the dev
   port (8788):
   ```bash
   pkill -9 -f "fyolo-dev.app/Contents/MacOS/fyolo" || true
   pkill -9 -f "cloudflared tunnel --url http://127.0.0.1:8788" || true
   pkill -9 -f "tunelo port 8788" || true
   ```

2. **Build the dev bundle** from the committed `packaging/AppIcon.png` — do *not*
   re-render the icon (see "Icons" below). Show the tail of the output; if the
   build fails, show the error and **stop — do NOT relaunch**:
   ```bash
   FYOLO_CHANNEL=dev ./scripts/build-app.sh 2>&1 | tail -12
   ```

3. **Re-register the dev bundle with LaunchServices, then refresh the Dock cache.**
   macOS resolves an app's icon by its bundle id (`sh.fyolo.app.dev`); `lsregister -f`
   forces our path to win and `killall Dock` drops the cached icon:
   ```bash
   LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
   "$LSREG" -f "$PWD/fyolo-dev.app"
   touch ./fyolo-dev.app
   killall Dock 2>/dev/null || true
   ```

4. **Relaunch via `open`** (NOT `nohup` on the inner binary — that bypasses
   LaunchServices). `open`'s `--stdout` / `--stderr` still capture logs:
   ```bash
   open ./fyolo-dev.app --stdout /tmp/fyolo-dev.log --stderr /tmp/fyolo-dev.log
   echo "launched ./fyolo-dev.app (logs: /tmp/fyolo-dev.log)"
   ```

5. **Upgrade the running dev daemon.** `build-app.sh` already rebuilt the
   daemon into `Resources/fyolod`, but a **running** dev daemon keeps its old
   image: a dev app's launch-time reconcile deliberately refuses to stage
   (its bundle stamp is a placeholder, and that guard is what keeps a dev
   build from ever deploying itself over a release daemon). Without this
   step, a fyolod-side change gets "verified" against the previous daemon.
   The deploy is idempotent — same version reports `current` and does
   nothing, so it costs nothing on Swift-only rebuilds — and an execve
   handoff keeps the pid and carries every live session. `FYOLOD_SOCK` must
   be unset first: a shell inside a fyolo session carries it pointed at the
   *release* daemon, and it overrides the channel.
   ```bash
   unset FYOLOD_SOCK
   FYOLO_CHANNEL=dev ./fyolo-dev.app/Contents/Resources/fyolod deploy --json 2>&1 | tail -3
   ```
   A daemon that isn't running needs nothing: the first pane starts it from
   the new bundle.

6. **Report** the result: whether the build succeeded, the app relaunched, and
   the daemon version the deploy reported. If the window doesn't appear, check
   `/tmp/fyolo-dev.log`.

## Seeing the first-launch onboarding

`scripts/dev-onboarding.sh` kills the dev app, backs up and clears its session
tree, defaults, and dev-only GitHub token, and relaunches it as a fresh install —
the release app is never touched. `--keep-recents` / `--keep-github` keep the
Recent list or the GitHub connection (to see the repository list); `--restore`
puts everything except the token back.

## Verifying a fyolod-side change

Sessions carried across the handoff keep the environment and shell their
**old** daemon spawned them with — a change to session spawning (env,
injection, PTY setup) is invisible in them by design. Open a **new** session
to see it.

## Icons

`scripts/render-icon.sh` rasterizes `packaging/icon-static.svg` into
`packaging/AppIcon.png` (and the iOS asset) through headless Chrome — and its
output is **not reproducible**: rendering the same SVG twice writes two different
files, neither matching the committed one. Running it on every rebuild therefore
dirtied the tree with two unreviewable binary diffs, cost a Chrome launch, and
risked overwriting hand-touched artwork. So it is not part of this loop.

Re-render only when the SVG actually changed, and commit the PNGs as their own
change:

```bash
./scripts/render-icon.sh && git add packaging/AppIcon.png \
  ios/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

## Notes

- This builds **release configuration** (via `build-app.sh`) into the dev *channel*
  bundle, so it's a few seconds slower than a bare `swift build`. For quick code-only
  iteration without a bundle, run `swift build` and launch
  `"$(swift build --show-bin-path)/fyolo"` directly — but that has no Dock icon and,
  running unbundled, uses `AppChannel.suffix == ""` (i.e. the *release* state dir and
  port 8787), so it is **not** isolated. Use the bundle when you need isolation.
- A concurrent SwiftPM process holding the `.build` lock can make a build emit
  spurious errors mid-write; if that happens, just rerun.
- Do NOT modify `Package.swift` or sources during a rebuild.
- After rebuilding a UI change, pair this with the `app-screenshot-debug` skill to
  actually *see* the result.

#!/usr/bin/env bash
# Puts the dev app (fyolo-dev.app) back at its first launch, so the welcome
# page's onboarding can be seen the way a new user sees it — and puts the real
# dev state back afterwards. The release app's state is never touched: every
# path, defaults domain, and Keychain item here is the dev channel's own.
#
#   scripts/dev-onboarding.sh                  fresh install: no sessions, no Recent, GitHub not connected
#   scripts/dev-onboarding.sh --keep-recents   ...but keep the Recent folders
#   scripts/dev-onboarding.sh --keep-github    ...but stay connected, to see the repository list
#   scripts/dev-onboarding.sh --restore        put the saved session tree and defaults back
#
# Resetting twice in a row keeps the first backup, so the state that comes back
# is always the one from before testing began. The GitHub token is deleted, not
# backed up — reconnect from the welcome page or the Issues pane afterwards.
# Sessions the dev daemon is running stay alive throughout; they reappear when
# the session tree is restored.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo_root/fyolo-dev.app"
domain="sh.fyolo.app.dev"
support="$HOME/Library/Application Support/fyolo-dev"
backup="$support/onboarding-backup"
keychain_service="sh.fyolo.app.issues-dev"

keep_recents=false
keep_github=false
restore=false
for argument in "$@"; do
  case "$argument" in
    --keep-recents) keep_recents=true ;;
    --keep-github) keep_github=true ;;
    --restore) restore=true ;;
    *) echo "unknown option: $argument" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$app" ]]; then
  echo "no $app — build it first: FYOLO_CHANNEL=dev ./scripts/build-app.sh" >&2
  exit 1
fi

# Match the dev bundle's path, never `pkill -x fyolo`, which would also take the
# release app down (both executables are named `fyolo`).
pkill -9 -f "fyolo-dev.app/Contents/MacOS/fyolo" || true
sleep 0.5

if $restore; then
  if [[ ! -d "$backup" ]]; then
    echo "nothing to restore: no backup at $backup" >&2
    exit 1
  fi
  rm -f "$support/state.json"
  [[ -f "$backup/state.json" ]] && mv "$backup/state.json" "$support/state.json"
  defaults delete "$domain" >/dev/null 2>&1 || true
  [[ -f "$backup/defaults.plist" ]] && defaults import "$domain" "$backup/defaults.plist"
  rm -rf "$backup"
  echo "restored the dev session tree and defaults"
else
  mkdir -p "$backup"
  if [[ ! -f "$backup/defaults.plist" ]]; then
    defaults export "$domain" "$backup/defaults.plist" 2>/dev/null \
      || plutil -create xml1 "$backup/defaults.plist"
    [[ -f "$support/state.json" ]] && mv "$support/state.json" "$backup/state.json"
  fi
  rm -f "$support/state.json"

  # A fresh defaults domain, minus the Recent list when it is being kept.
  fresh="$(mktemp -t fyolo-onboarding)"
  python3 - "$backup/defaults.plist" "$fresh" "$keep_recents" <<'PYTHON'
import plistlib, sys
source, target, keep_recents = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
with open(source, "rb") as f:
    saved = plistlib.load(f)
kept = {k: v for k, v in saved.items() if keep_recents and k == "welcome.recentProjects"}
with open(target, "wb") as f:
    plistlib.dump(kept, f)
PYTHON
  defaults delete "$domain" >/dev/null 2>&1 || true
  defaults import "$domain" "$fresh"
  rm -f "$fresh"

  if ! $keep_github; then
    security delete-generic-password -s "$keychain_service" -a github >/dev/null 2>&1 || true
  fi
  echo "reset the dev app to first launch (backup: $backup)"
  echo "run 'scripts/dev-onboarding.sh --restore' to put it back"
fi

open "$app" --stdout /tmp/fyolo-dev.log --stderr /tmp/fyolo-dev.log
echo "launched $app (logs: /tmp/fyolo-dev.log)"

#!/usr/bin/env bash
# Print the latest.json a release publishes beside its DMG. The app fetches it
# from https://github.com/<repo>/releases/latest/download/latest.json, which
# GitHub redirects to the newest published release — no API, no rate limit.
#
#   version          this release
#   minimum_version  the oldest release still allowed to run: the higher of
#                    <major>.0.0 (a new major forces everyone onto it) and
#                    packaging/minimum-version (the deliberate exceptions)
#   dmg_url, sha256  what a direct install downloads and verifies
#   cask             what a Homebrew install upgrades
#
# Usage: scripts/release-manifest.sh <version> <dmg path> > latest.json
# GITHUB_REPOSITORY (set in Actions) names the repo; it defaults to fl0wo/fyolo.
set -euo pipefail

version="${1:?usage: release-manifest.sh <version> <dmg path>}"
dmg="${2:?usage: release-manifest.sh <version> <dmg path>}"
repo="${GITHUB_REPOSITORY:-fl0wo/fyolo}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

semver='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ ! "$version" =~ $semver ]]; then
    echo "error: version '$version' is not MAJOR.MINOR.PATCH" >&2
    exit 1
fi

floor="$(grep -v '^[[:space:]]*#' "$repo_root/packaging/minimum-version" | tr -d '[:space:]')"
if [[ ! "$floor" =~ $semver ]]; then
    echo "error: packaging/minimum-version holds '$floor', not MAJOR.MINOR.PATCH" >&2
    exit 1
fi

major_floor="${version%%.*}.0.0"
minimum="$(printf '%s\n%s\n' "$floor" "$major_floor" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
# A floor above the release itself would tell every install, this one
# included, that no version may run.
highest="$(printf '%s\n%s\n' "$minimum" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
if [[ "$highest" != "$version" ]]; then
    echo "error: minimum version $minimum is above the release $version" >&2
    exit 1
fi

sha256="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"

jq -n \
    --arg version "$version" \
    --arg minimum "$minimum" \
    --arg notes "https://github.com/$repo/releases/tag/v$version" \
    --arg dmg "https://github.com/$repo/releases/download/v$version/fyolo.dmg" \
    --arg sha256 "$sha256" \
    --arg cask "fl0wo/tap/fyolo" \
    '{version: $version, minimum_version: $minimum, notes_url: $notes,
      dmg_url: $dmg, sha256: $sha256, cask: $cask}'

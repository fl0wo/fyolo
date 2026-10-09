#!/usr/bin/env bash
# One-time helper to prepare the GitHub secrets the release workflow needs.
#
# It automates the deterministic, non-interactive parts — exporting the Sparkle
# signing key and verifying it matches the public key embedded in Info.plist —
# and prints a checklist for the certificate / notarization secrets that require
# files only you have. See docs/RELEASING.md for the full story.
#
# Usage:
#   ./scripts/setup-release.sh          # check + offer to set SPARKLE_ED_KEY
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

sparkle_version="2.9.3"
tools_dir="$HOME/.cache/sparkle-${sparkle_version}"
expected_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' packaging/Info.plist)"

echo "==> Ensuring Sparkle ${sparkle_version} tools"
if [[ ! -x "$tools_dir/bin/generate_keys" ]]; then
    mkdir -p "$tools_dir"
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/Sparkle-${sparkle_version}.tar.xz" \
        | tar xJ -C "$tools_dir" bin/generate_keys
fi
generate_keys="$tools_dir/bin/generate_keys"

echo "==> Verifying the keychain's Sparkle key matches Info.plist"
actual_key="$("$generate_keys" -p 2>/dev/null || true)"
if [[ -z "$actual_key" ]]; then
    echo "error: no Sparkle key found in your keychain. Run '$generate_keys' once" >&2
    echo "       to create one, then update SUPublicEDKey in packaging/Info.plist." >&2
    exit 1
fi
if [[ "$actual_key" != "$expected_key" ]]; then
    echo "error: keychain public key does not match packaging/Info.plist." >&2
    echo "       keychain:  $actual_key" >&2
    echo "       Info.plist: $expected_key" >&2
    echo "       Fix the SUPublicEDKey in Info.plist or use the matching key." >&2
    exit 1
fi
echo "    OK — public key matches: $expected_key"

if command -v gh >/dev/null 2>&1; then
    echo "==> Setting the SPARKLE_ED_KEY repository secret"
    key_file="$(mktemp -u)"   # -u: name only; generate_keys -x refuses to overwrite an existing file
    trap 'rm -f "$key_file"' EXIT
    "$generate_keys" -x "$key_file" >/dev/null
    gh secret set SPARKLE_ED_KEY < "$key_file"
    echo "    SPARKLE_ED_KEY set."
else
    echo "==> gh CLI not found — skipping SPARKLE_ED_KEY. Install gh, then re-run."
fi

cat <<'EOF'

==> Remaining secrets to set by hand — see docs/RELEASING.md:
    R2_ACCESS_KEY_ID             Cloudflare R2 token Access Key ID
    R2_SECRET_ACCESS_KEY         Cloudflare R2 token Secret Access Key
    R2_ENDPOINT                  https://<accountid>.r2.cloudflarestorage.com
    DEVELOPER_ID_CERT_P12        base64 of your exported Developer ID .p12
    DEVELOPER_ID_CERT_PASSWORD   that .p12's password
    ASC_API_KEY                  base64 of your App Store Connect .p8 key
    ASC_KEY_ID                   the 10-char Key ID
    ASC_ISSUER_ID                the Issuer ID (UUID)
    CLOUDFLARE_API_TOKEN         (optional) edge cache purge — Zone: Cache Purge
    CLOUDFLARE_ZONE_ID           (optional) the fyolo.sh zone ID

Then cut a release with:
    git tag v0.1.0 && git push origin v0.1.0
EOF

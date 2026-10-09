#!/bin/zsh
# Build FyoloMobile, install it on the first connected iPhone, and launch it
# pointed at this Mac's companion server. Usage: ./dev-run.sh [roster-url]
set -euo pipefail
cd "$(dirname "$0")"

# xctrace lists physical devices as "Name (OS) (UDID)"; the UDID works for
# both xcodebuild's `id=` destination and devicectl's `--device`.
DEVICE=$(xcrun xctrace list devices 2>/dev/null \
    | sed -n '/Simulators/q;p' \
    | grep -m1 'iPhone' \
    | sed -E 's/.*\(([0-9A-Fa-f-]+)\)[[:space:]]*$/\1/')
if [[ -z "${DEVICE}" ]]; then
    echo "No iPhone found. Plug it in (or pair over Wi-Fi) and trust this Mac." >&2
    echo "Devices xctrace can see:" >&2
    xcrun xctrace list devices >&2 || true
    exit 1
fi
echo "Device: ${DEVICE}"

MAC_IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
# The companion server refuses unauthenticated sockets; the pairing token
# lives in the Mac app's defaults (deliberately, so this script can read it).
TOKEN=$(defaults read sh.fyolo.app companion.pairingToken 2>/dev/null || true)
ROSTER_URL="${1:-ws://${MAC_IP}:8787${TOKEN:+/?t=${TOKEN}}}"
echo "Roster URL: ${ROSTER_URL}"

xcodebuild \
    -project FyoloMobile.xcodeproj \
    -scheme FyoloMobile \
    -configuration Debug \
    -destination "id=${DEVICE}" \
    -derivedDataPath build \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build

APP="build/Build/Products/Debug-iphoneos/FyoloMobile.app"
xcrun devicectl device install app --device "${DEVICE}" "${APP}"
xcrun devicectl device process launch --terminate-existing --device "${DEVICE}" \
    sh.fyolo.mobile -- -roster-url "${ROSTER_URL}"

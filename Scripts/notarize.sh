#!/bin/bash
#
# Notarize a signed monitor.app and staple the ticket to it.
#
# Usage:
#   Scripts/notarize.sh .build/monitor.app monitor-1.1.0.zip
#
# Needs a notarytool credential profile in the keychain, named by
# MONITOR_NOTARY_PROFILE. Create it once per machine:
#
#   xcrun notarytool store-credentials monitor-notary \
#       --apple-id you@example.com --team-id 94S5PZTVPY --password <app-specific>
#
# The zip is an argument rather than something this builds, because the caller
# has already made one and notarization takes an archive: the notary service
# does not accept a bare .app.
#
# **The zip is rebuilt at the end, and that is the point.** `stapler` writes the
# ticket into the bundle, not into the archive, so the copy that was uploaded is
# still unstapled. Publishing that one gives every downloader a Gatekeeper round
# trip to Apple on first launch, and a straight failure if they are offline.
#
# See docs/signing.md.

set -euo pipefail

app="${1:-}"
zip="${2:-}"
profile="${MONITOR_NOTARY_PROFILE:-}"

[ -d "$app" ] || { echo "usage: $0 <app> <zip>" >&2; exit 1; }
[ -f "$zip" ] || { echo "usage: $0 <app> <zip>" >&2; exit 1; }
[ -n "$profile" ] || { echo "MONITOR_NOTARY_PROFILE is not set" >&2; exit 1; }

# A bundle signed ad-hoc is refused by the notary service with a message that
# does not say so. Catching it here costs one command and a minute of waiting.
# Two traps in one line, both of which reported a correctly signed bundle as
# unsigned. `-dv` prints no Authority lines at all — that needs `-dvv`. And
# `grep -q` exits on the first match, which SIGPIPEs codesign, which under
# `set -o pipefail` fails the whole pipeline. Hence a capture and a test.
authority="$(codesign -dvv "$app" 2>&1 \
    | grep '^Authority=Developer ID Application' || true)"

if ! codesign --verify --strict --deep "$app" 2>/dev/null || [ -z "$authority" ]; then
    echo "error: $app is not signed with a Developer ID Application identity" >&2
    echo "       notarization would be rejected; see docs/signing.md" >&2
    exit 1
fi

echo "Submitting ${zip} to the notary service…"
# --wait, because the whole point here is that the zip we publish is stapled,
# and stapling needs the ticket to exist. Apple usually answers in a couple of
# minutes.
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait

echo "Stapling the ticket to ${app}…"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

echo "Rebuilding ${zip} around the stapled bundle…"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

# Gatekeeper's own verdict, which is the question a downloader is really asking.
# It reads the staple rather than calling Apple, so this passes with the network
# off — which is the difference stapling buys.
spctl --assess --type execute --verbose=2 "$app"

echo "Notarized and stapled."

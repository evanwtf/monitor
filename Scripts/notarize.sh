#!/bin/bash
#
# Notarize a signed monitor.app and the tools beside it, and staple the ticket
# to the app.
#
# Usage:
#   Scripts/notarize.sh .build/package
#
# The argument is the package directory that make-app.sh stages: monitor.app/,
# monitord, monitor-exporter and install-exporter.sh side by side. All of it
# goes to the notary service in one submission, so the tools are notarized as
# well as the app.
#
# Needs a notarytool credential profile in the keychain, named by
# MONITOR_NOTARY_PROFILE. Create it once per machine:
#
#   xcrun notarytool store-credentials monitor-notary \
#       --apple-id you@example.com --team-id 94S5PZTVPY --password <app-specific>
#
# The submission zip is made here and thrown away. The notary service takes an
# archive, not a bare .app, but what is published is built afterwards from the
# stapled bundle: the disk image by Scripts/make-dmg.sh, and the tools zip by
# package.yml.
#
# **Staple before packaging, and that is the point.** `stapler` writes the
# ticket into the bundle, not into any archive around it. An archive made
# before stapling holds an unstapled app, which gives every downloader a
# Gatekeeper round trip to Apple on first launch, and a straight failure if
# they are offline. The bare tools cannot hold a ticket at all; Gatekeeper
# looks theirs up online.
#
# See docs/signing.md.

set -euo pipefail

package="${1:-}"
profile="${MONITOR_NOTARY_PROFILE:-}"

[ -d "$package" ] || { echo "usage: $0 <package>" >&2; exit 1; }
[ -n "$profile" ] || { echo "MONITOR_NOTARY_PROFILE is not set" >&2; exit 1; }

app="$package/monitor.app"
[ -d "$app" ] || { echo "no monitor.app in $package" >&2; exit 1; }

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

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
submission="$scratch/submission.zip"
# ditto, not zip: a bundle holds symlinks and extended attributes, and zip
# flattens them.
ditto -c -k "$package" "$submission"

echo "Submitting ${package} to the notary service…"
# --wait, because stapling needs the ticket to exist. Apple usually answers in
# a couple of minutes.
xcrun notarytool submit "$submission" --keychain-profile "$profile" --wait

echo "Stapling the ticket to ${app}…"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

# Gatekeeper's own verdict, which is the question a downloader is really asking.
# It reads the staple rather than calling Apple, so this passes with the network
# off — which is the difference stapling buys.
spctl --assess --type execute --verbose=2 "$app"

echo "Notarized and stapled."

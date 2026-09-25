#!/bin/bash
#
# Put monitor.app in a disk image beside a link to /Applications, so that
# installing it is one drag.
#
# Usage:
#   Scripts/make-dmg.sh .build/package/monitor.app monitor-1.9.0.dmg
#
# Only the app goes in the image. The headless tools ship in their own zip:
# a drag-to-Applications window offers one gesture, and binaries beside the
# app would make it unclear what to drag.
#
# Signing and notarizing follow make-app.sh and notarize.sh:
#
#   MONITOR_SIGN_IDENTITY   codesign identity for the image. Set, signing must
#                           succeed. Unset, a "Developer ID Application"
#                           identity in the keychain is used if there is one,
#                           and the image is left unsigned if not.
#   MONITOR_NOTARY_PROFILE  notarytool profile. Set, the image is notarized
#                           and stapled too, and the image must be signed.
#
# Notarize and staple the app *before* this runs (Scripts/notarize.sh). The
# ticket stapled to the image covers the image. The ticket stapled to the app
# travels with the app when it is dragged out, so it opens offline.
#
# No background picture and no icon positions. Both live in a .DS_Store that
# only Finder writes: scripting Finder on the runner is fragile, and a
# committed .DS_Store is a binary blob. The plain window still shows the app
# and the Applications link side by side.
#
# See docs/signing.md.

set -euo pipefail

app="${1:-}"
dmg="${2:-}"
[ -d "$app" ] && [ -n "$dmg" ] || { echo "usage: $0 <monitor.app> <out.dmg>" >&2; exit 1; }
profile="${MONITOR_NOTARY_PROFILE:-}"

identity="${MONITOR_SIGN_IDENTITY:-}"
required=1
if [ -z "$identity" ]; then
    required=0
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
if [ -n "$profile" ] && [ -z "$identity" ]; then
    echo "error: MONITOR_NOTARY_PROFILE is set, but there is no identity to sign with" >&2
    echo "       the notary service refuses an unsigned image" >&2
    exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# ditto, not cp: it keeps the bundle's symlinks, extended attributes and the
# stapled ticket exactly as they are.
ditto "$app" "$stage/monitor.app"
ln -s /Applications "$stage/Applications"

echo "Creating ${dmg}…"
rm -f "$dmg"
# UDZO: compressed and read-only, the format every downloaded image uses.
#
# macOS 27 prints a deprecation warning for hdiutil and points at `diskutil
# image`. Kept anyway: `diskutil image create from` takes a disk or an image,
# not a folder, so replacing -srcfolder means creating a blank image, mounting
# it, copying the app in and converting it — four new ways to fail for a
# command that still works. If hdiutil goes, this line fails the release
# loudly, and that sequence is the replacement.
hdiutil create -volname "Monitor" -srcfolder "$stage" -format UDZO -ov "$dmg" >/dev/null
hdiutil verify "$dmg" >/dev/null

if [ -n "$identity" ]; then
    echo "Signing ${dmg} as ${identity}…"
    if ! codesign --force --timestamp --sign "$identity" "$dmg"; then
        echo "error: could not sign $dmg as $identity" >&2
        exit 1
    fi
    codesign --verify --strict --verbose=2 "$dmg" 2>&1 | sed 's/^/  /'
elif [ "$required" -eq 1 ]; then
    echo "error: MONITOR_SIGN_IDENTITY is set but empty" >&2
    exit 1
else
    echo "Unsigned — fine locally, blocked by Gatekeeper on another Mac."
fi

if [ -n "$profile" ]; then
    echo "Submitting ${dmg} to the notary service…"
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
    echo "Stapling the ticket to ${dmg}…"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    # Gatekeeper's verdict on opening the image, which is what a downloader
    # does first. It reads the staple, so it passes with the network off.
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

echo "Built $dmg"

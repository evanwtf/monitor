#!/bin/bash
#
# Wrap the release binary in a real .app bundle.
#
# The bundle is what gives the app an identity macOS understands: a Dock icon, a
# Cmd-Tab entry, a name in the menu bar, and a stable bundle id for anything
# that remembers a per-app decision. `swift run monitor` asks for the same
# foreground identity at runtime, which is enough to develop against — this is
# for having the app somewhere you can launch it from.
#
# Usage:
#   Scripts/make-app.sh              # build into .build/monitor.app
#   Scripts/make-app.sh ~/Applications   # and copy it there
#
# Signing is by identity when there is one and ad-hoc when there is not:
#
#   MONITOR_SIGN_IDENTITY   codesign identity. Set it and signing must succeed;
#                           the script fails rather than quietly shipping an
#                           ad-hoc bundle nobody can install.
#   unset                   a "Developer ID Application" identity in the
#                           keychain is used if one is there, and an ad-hoc
#                           signature if not.
#
# An ad-hoc signature is right for a local build — it keeps the app's identity
# stable across rebuilds so macOS does not forget what it remembered about it —
# and useless for shipping, because Gatekeeper rejects a downloaded copy. See
# docs/signing.md.

set -euo pipefail

readonly BUNDLE_ID="wtf.evan.monitor"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# One version, and it lives in the source so the About panel and the bundle
# cannot disagree.
VERSION="$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' \
    Sources/MonitorCore/Version.swift)"
[ -n "$VERSION" ] || { echo "no version in Sources/MonitorCore/Version.swift" >&2; exit 1; }
readonly VERSION

destination="${1:-}"
app=".build/monitor.app"

# The icon is drawn by a script rather than checked in, so the palette has one
# home. Rebuilt only when the drawing changes — it costs a few seconds.
icon=".build/AppIcon.icns"
if [ ! -f "$icon" ] || [ Scripts/make-icon.swift -nt "$icon" ]; then
    echo "Drawing icon…"
    swift Scripts/make-icon.swift "$icon"
fi

echo "Building release…"
swift build -c release --product monitor

binary="$(swift build -c release --product monitor --show-bin-path)/monitor"
[ -x "$binary" ] || { echo "no binary at $binary" >&2; exit 1; }

echo "Assembling ${app}…"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/monitor"
cp "$icon" "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Monitor</string>
    <key>CFBundleDisplayName</key>
    <string>Monitor</string>
    <key>CFBundleExecutable</key>
    <string>monitor</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT licensed. Copyright © 2026 Evan Hoffman.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- The window is designed against a dark ground; see Theme. -->
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
</dict>
</plist>
PLIST

# The identity to sign with: whatever was asked for, or a Developer ID in the
# keychain, or nothing.
identity="${MONITOR_SIGN_IDENTITY:-}"
required=1
if [ -z "$identity" ]; then
    required=0
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi

if [ -n "$identity" ]; then
    # --options runtime and a secure timestamp are not optional extras: the
    # notary service rejects a bundle without either, and both are impossible
    # to add afterwards without signing again.
    echo "Signing as ${identity}…"
    if ! codesign --force --deep --options runtime --timestamp \
            --sign "$identity" "$app"; then
        echo "error: could not sign $app as $identity" >&2
        exit 1
    fi
    codesign --verify --strict --verbose=2 "$app" 2>&1 | sed 's/^/  /'
elif [ "$required" -eq 1 ]; then
    echo "error: MONITOR_SIGN_IDENTITY is set but empty" >&2
    exit 1
else
    # Ad-hoc. Without a signature the bundle still runs, but macOS treats it as
    # a different app on every rebuild and forgets anything it remembered.
    codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 \
        || echo "warning: could not sign $app; it will still run" >&2
    echo "Signed ad-hoc — fine locally, not installable on another Mac."
fi

echo "Built $app"

if [ -n "$destination" ]; then
    mkdir -p "$destination"
    rm -rf "${destination%/}/monitor.app"
    cp -R "$app" "${destination%/}/monitor.app"
    echo "Installed ${destination%/}/monitor.app"
else
    echo "Run it with: open $app"
fi

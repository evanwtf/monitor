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
# No signing identity is used. The bundle is signed ad-hoc, which is what a
# locally built app needs to keep a stable identity across launches. Shipping it
# to another Mac needs a Developer ID and notarization, which this does not do.

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

# Ad-hoc signature. Without one the bundle still runs, but macOS treats it as a
# different app on every rebuild and forgets anything it remembered about it.
codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 \
    || echo "warning: could not sign $app; it will still run" >&2

echo "Built $app"

if [ -n "$destination" ]; then
    mkdir -p "$destination"
    rm -rf "${destination%/}/monitor.app"
    cp -R "$app" "${destination%/}/monitor.app"
    echo "Installed ${destination%/}/monitor.app"
else
    echo "Run it with: open $app"
fi

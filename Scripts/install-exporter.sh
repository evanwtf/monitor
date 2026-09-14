#!/bin/bash
#
# Install monitor-exporter as a compiled binary and run it as a launchd agent,
# so metrics are served without a Swift toolchain and without `swift run`.
#
#   ./install-exporter.sh          # from an unpacked release zip
#   Scripts/install-exporter.sh    # from a repo checkout
#
# The script works out which of the two it is in. In a release zip the signed
# binary sits beside this script and is installed as it is -- re-signing would
# break its notarization, and a machine that downloaded a zip has no reason to
# own a toolchain. In a checkout there is no binary yet, so it builds a release
# one first.
#
# What it does, in order:
#   1. Finds a binary: the one beside this script, or a fresh release build
#      (built as you, not root -- building under sudo would leave root-owned
#      artifacts).
#   2. Installs it to /usr/local/bin/monitor-exporter (root-owned, like any
#      system binary). This is the compiled binary you then run directly.
#   3. Writes a per-user LaunchAgent that runs that binary at login and keeps
#      it alive, and (re)loads it so it is serving now.
#   4. Scrapes the endpoint once to confirm it answers.
#
# Configure the listener before running:
#   MONITOR_EXPORTER_PORT      TCP port. Default 9650.
#   MONITOR_EXPORTER_ADDRESS   Bind address. Default 127.0.0.1; 0.0.0.0 to let a
#                              remote Prometheus reach it (firewall the port).
#
# Idempotent: re-running rebuilds, reinstalls, rewrites the plist only when its
# content differs, and reloads the agent.
#
# To remove it:
#   launchctl bootout "gui/$(id -u)/wtf.evan.monitor-exporter"
#   rm ~/Library/LaunchAgents/wtf.evan.monitor-exporter.plist
#   sudo rm /usr/local/bin/monitor-exporter
#
# Needs sudo only for step 2; the agent must load as you, not root, so the rest
# runs as the invoking user.

set -euo pipefail

readonly LABEL="wtf.evan.monitor-exporter"
readonly INSTALL_PATH="/usr/local/bin/monitor-exporter"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] \
    || fail "run as yourself, not under sudo; a LaunchAgent must load as your user, and the script elevates only for the install step"

port="${MONITOR_EXPORTER_PORT:-9650}"
address="${MONITOR_EXPORTER_ADDRESS:-127.0.0.1}"
[[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
    || fail "MONITOR_EXPORTER_PORT must be 1-65535, not '$port'"

# Step 1: find a binary.
if [ -x "$here/monitor-exporter" ]; then
    # Release zip: the binary is signed and notarized already.
    bin="$here/monitor-exporter"
    echo "Installing the binary from ${here}…"
elif [ -f "$here/../Package.swift" ]; then
    # Repo checkout: build a release one.
    cd "$here/.."
    command -v swift >/dev/null \
        || fail "no swift toolchain; install Xcode or the command line tools"
    echo "Building release…"
    swift build -c release --product monitor-exporter
    bin="$(swift build -c release --product monitor-exporter --show-bin-path)/monitor-exporter"
    [ -x "$bin" ] || fail "no binary at $bin; fix the build first"
else
    fail "no monitor-exporter binary beside this script and no Package.swift above it; run it from an unpacked release zip or a repo checkout"
fi

# Step 2: install the compiled binary.
sudo mkdir -p /usr/local/bin
echo "Installing ${INSTALL_PATH}…"
sudo /usr/bin/install -m 0755 "$bin" "$INSTALL_PATH"
# A binary out of a downloaded zip carries com.apple.quarantine, which survives
# the copy. Dropping it on a binary we just installed costs nothing.
sudo xattr -d com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

# Step 3: write and load the LaunchAgent.
agents="$HOME/Library/LaunchAgents"
logs="$HOME/Library/Logs"
mkdir -p "$agents" "$logs"
plist="$agents/$LABEL.plist"
log="$logs/monitor-exporter.log"

tmp="$(mktemp /tmp/monitor-exporter-plist.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_PATH</string>
        <string>--bind-port</string>
        <string>$port</string>
        <string>--bind-address</string>
        <string>$address</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$log</string>
    <key>StandardErrorPath</key>
    <string>$log</string>
</dict>
</plist>
EOF

if cmp -s "$tmp" "$plist" 2>/dev/null; then
    echo "LaunchAgent unchanged: $plist"
else
    echo "Writing ${plist}…"
    /usr/bin/install -m 0644 "$tmp" "$plist"
fi

domain="gui/$(id -u)"
# bootout an existing instance first so a reinstall picks up the new binary and
# any changed port; ignore the error when it is not loaded yet.
launchctl bootout "$domain/$LABEL" 2>/dev/null || true
launchctl bootstrap "$domain" "$plist"
launchctl kickstart -k "$domain/$LABEL"

# Step 4: confirm it answers.
echo "Waiting for the endpoint…"
if curl --retry 20 --retry-connrefused --retry-delay 1 -fsS "http://127.0.0.1:$port/metrics" \
        | grep -q monitor_exporter_build_info; then
    echo "monitor-exporter is serving /metrics on ${address}:${port}"
    echo "Point Prometheus at ${address}:${port}; logs at ${log}"
else
    fail "the endpoint did not answer on port $port; check $log"
fi

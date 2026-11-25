#!/bin/bash
# Install the optional guard as a per-user LaunchAgent.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/Library/Application Support/ClaudeHiddify"
AGENT="$HOME/Library/LaunchAgents"
PLIST="$AGENT/com.user.claude-hiddify-guard.plist"

mkdir -p "$DEST" "$AGENT"
install -m 755 "$HERE/claude-hiddify-guard.sh" "$DEST/claude-hiddify-guard.sh"
install -m 644 "$HERE/com.user.claude-hiddify-guard.plist" "$PLIST"

launchctl bootout "gui/$(id -u)/com.user.claude-hiddify-guard" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/com.user.claude-hiddify-guard" >/dev/null 2>&1 || true
echo "guard installed: $DEST/claude-hiddify-guard.sh"
echo "log: /tmp/claude-hiddify-guard.log"

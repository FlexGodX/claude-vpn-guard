#!/bin/bash
#
# Remove the Claude/Hiddify enforcement and restore managed settings from the
# most recent install backup.  Run as root:
#
#   sudo ./uninstall.sh
#
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "This uninstaller must run as root. Use: sudo $0" >&2
  exit 1
fi

STATE_DIR="/Library/Application Support/ClaudeHiddify"
PF_CONF="/etc/pf.conf"
ANCHOR_NAME="com.user.claude-hiddify"
ANCHOR_FILE="/etc/pf.anchors/$ANCHOR_NAME"
TABLE_DIR="/etc/claude-hiddify"
DAEMON="/Library/LaunchDaemons/com.user.claude-hiddify-pf.plist"
PF_SCRIPT="/usr/local/sbin/claude-hiddify-pf"
PLIST_MACHINE="/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
PLIST_USER="/Library/Managed Preferences/Administrator/com.anthropic.claudefordesktop.plist"
CC_MANAGED="/Library/Application Support/ClaudeCode/managed-settings.json"
HOSTS_FILE="/etc/hosts"
HOSTS_BEGIN="# BEGIN claude-hiddify telemetry block"
HOSTS_END="# END claude-hiddify telemetry block"
PFCTL="/sbin/pfctl"

LATEST="$(ls -dt "$STATE_DIR"/backup-* 2>/dev/null | head -1 || true)"

echo "== Stopping boot-time loader =="
launchctl bootout system/com.user.claude-hiddify-pf >/dev/null 2>&1 || true
rm -f "$DAEMON" "$PF_SCRIPT"

echo "== Removing pf anchor =="
"$PFCTL" -a "$ANCHOR_NAME" -F all >/dev/null 2>&1 || true

if /usr/bin/grep -qxF "anchor \"$ANCHOR_NAME\"" "$PF_CONF"; then
  TMP_PF="$(mktemp /tmp/claude-hiddify-uninstall.XXXXXX)"
  /usr/bin/grep -vxF "anchor \"$ANCHOR_NAME\"" "$PF_CONF" > "$TMP_PF"
  if "$PFCTL" -n -f "$TMP_PF" >/dev/null 2>&1; then
    /bin/cat "$TMP_PF" > "$PF_CONF"
    "$PFCTL" -f "$PF_CONF" >/dev/null 2>&1 || true
  else
    echo "WARNING: edited pf.conf failed syntax check; leaving it untouched" >&2
  fi
  rm -f "$TMP_PF"
fi

rm -f "$ANCHOR_FILE" "$TABLE_DIR/anthropic4.txt" "$TABLE_DIR/anthropic6.txt"
rmdir "$TABLE_DIR" >/dev/null 2>&1 || true

echo "== Removing Claude telemetry hosts block =="
if /usr/bin/grep -qF "$HOSTS_BEGIN" "$HOSTS_FILE"; then
  TMP_HOSTS="$(mktemp /tmp/claude-hiddify-hosts.XXXXXX)"
  /usr/bin/awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    !skip { print }
  ' "$HOSTS_FILE" > "$TMP_HOSTS"
  /bin/cat "$TMP_HOSTS" > "$HOSTS_FILE"
  rm -f "$TMP_HOSTS"
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
  /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
  echo "hosts block removed"
fi

restore_or_remove() {
  local dst="$1"
  local src="$LATEST$dst"
  if [[ -n "$LATEST" && -f "$src" ]]; then
    install -m 644 -o root -g wheel "$src" "$dst"
    echo "restored $dst"
  else
    rm -f "$dst"
    echo "removed $dst"
  fi
}

echo "== Restoring managed settings =="
restore_or_remove "$PLIST_MACHINE"
restore_or_remove "$PLIST_USER"
restore_or_remove "$CC_MANAGED"

killall cfprefsd >/dev/null 2>&1 || true

echo
echo "== Uninstalled =="
if [[ -n "$LATEST" ]]; then
  echo "Backups kept in: $LATEST"
  echo "The original pf.conf is at: $LATEST$PF_CONF"
fi
echo "Restart Claude to apply the restored settings."

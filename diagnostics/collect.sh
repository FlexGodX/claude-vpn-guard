#!/bin/bash
#
# Read-only diagnostic report for the Claude VPN guard.
# Run as the desktop user; run with sudo for the pf details.
#
#   ./diagnostics/collect.sh > /tmp/claude-vpn-report.txt
#   sudo ./diagnostics/collect.sh > /tmp/claude-vpn-report.txt
#
# The report intentionally omits VPN profile credentials, Claude account/org
# UUIDs and tokens.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CLAUDE_VPN_CONFIG:-$PROJECT_DIR/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi
: "${VPN_MODE:=auto}"
: "${VPN_NAME:=VPN}"
: "${VPN_PROCESS:=}"
: "${VPN_PROXY_URL:=http://127.0.0.1:12334}"
: "${ANTHROPIC_IP:=160.79.104.10}"
: "${ANTHROPIC_PROBE_URL:=https://api.anthropic.com/}"
: "${ANTHROPIC4_CIDR:=160.79.104.0/21}"
: "${ANTHROPIC6_CIDR:=2607:6bc0::/32}"
: "${SENTRY_HOSTS:=o1158394.ingest.us.sentry.io}"

ANCHOR="com.user.claude-hiddify"
PFCTL="/sbin/pfctl"
EUID_NOW="${EUID:-$(id -u)}"

route_iface() {
  /sbin/route -n get "$1" 2>/dev/null | /usr/bin/awk '/interface:/{print $2}'
}

echo "== Claude VPN guard diagnostic report =="
date
sw_vers
echo "user=$(id -un) uid=$EUID_NOW"
echo "config=$CONFIG_FILE"
echo "vpn=$VPN_NAME mode=$VPN_MODE process=${VPN_PROCESS:-<any>} proxy=$VPN_PROXY_URL"
echo

echo "== VPN services =="
/usr/sbin/scutil --nc list 2>/dev/null | head -20 || true
if [[ -n "$VPN_PROCESS" ]]; then
  /usr/bin/pgrep -fl "$VPN_PROCESS" 2>/dev/null || echo "process '$VPN_PROCESS' is not running"
fi
echo

echo "== Routing / mode =="
ANTHROPIC_IF="$(route_iface "$ANTHROPIC_IP")"
DEFAULT_IF="$(route_iface default)"
echo "Anthropic via ${ANTHROPIC_IF:-unknown}; default via ${DEFAULT_IF:-unknown}"
echo "-- default --"
/sbin/route -n get default 2>/dev/null | head -6 || true
echo "-- Anthropic --"
/sbin/route -n get "$ANTHROPIC_IP" 2>/dev/null | head -6 || true
echo "-- interfaces --"
ifconfig -l | tr ' ' '\n' | grep -E '^(en|utun|bridge|ppp|ipsec)' || true
for i in $(ifconfig -l | tr ' ' '\n' | grep '^utun'); do
  echo "[$i]"
  ifconfig "$i" 2>/dev/null | head -6 || true
done
echo

echo "== System proxy =="
/usr/sbin/scutil --proxy | grep -E 'HTTPEnable|HTTPProxy|HTTPPort|HTTPSEnable|HTTPSProxy|HTTPSPort|SOCKSEnable|SOCKSProxy|SOCKSPort' || true
echo

echo "== VPN path to Anthropic =="
if [[ "$ANTHROPIC_IF" == utun* ]]; then
  echo "mode=tun iface=$ANTHROPIC_IF"
  /usr/bin/curl -4 --noproxy '*' -sS -m 10 -o /dev/null -w 'anthropic_http=%{http_code} ip=%{remote_ip}\n' "$ANTHROPIC_PROBE_URL" 2>&1 || true
  /usr/bin/curl -4 --noproxy '*' -sS -m 10 https://api.ipify.org 2>/dev/null || echo "<no exit IP>"
else
  echo "mode=proxy/direct iface=${ANTHROPIC_IF:-unknown}"
  /usr/bin/curl -4 -x "$VPN_PROXY_URL" -sS -m 10 -o /dev/null -w 'proxy_http=%{http_code}\n' "$ANTHROPIC_PROBE_URL" 2>&1 || true
  /usr/bin/curl -4 --noproxy '*' -sS -m 5 -o /dev/null -w 'direct_http=%{http_code}\n' "$ANTHROPIC_PROBE_URL" 2>&1 || true
  /usr/bin/curl -4 -x "$VPN_PROXY_URL" -sS -m 10 https://api.ipify.org 2>/dev/null || echo "<no exit IP>"
fi
echo

echo "== pf anchor =="
if [[ "$EUID_NOW" -eq 0 ]]; then
  "$PFCTL" -a "$ANCHOR" -sr 2>/dev/null || echo "anchor $ANCHOR is not loaded"
  echo "-- tables --"
  "$PFCTL" -a "$ANCHOR" -t anthropic4 -T show 2>/dev/null || true
  "$PFCTL" -a "$ANCHOR" -t anthropic6 -T show 2>/dev/null || true
else
  echo "run with sudo for pf rules:"
  echo "  sudo $PFCTL -a $ANCHOR -sr"
  echo "  sudo $PFCTL -a $ANCHOR -t anthropic4 -T show"
fi
echo

echo "== Managed Claude policies =="
if [[ -f "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist" ]]; then
  /usr/bin/plutil -p "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
else
  echo "missing Claude Desktop managed plist"
fi
echo "-- Claude Code --"
if [[ -f "/Library/Application Support/ClaudeCode/managed-settings.json" ]]; then
  cat "/Library/Application Support/ClaudeCode/managed-settings.json"
else
  echo "missing Claude Code managed settings"
fi
echo

echo "== Telemetry hosts block =="
/usr/bin/awk '/BEGIN claude-hiddify telemetry block/,/END claude-hiddify telemetry block/' /etc/hosts 2>/dev/null || true
for host in $SENTRY_HOSTS; do
  /usr/bin/dscacheutil -q host -a name "$host" 2>/dev/null | grep -E 'name:|ip_address:' || true
done
echo

echo "== Claude processes / connections =="
/usr/bin/pgrep -fl '/Applications/Claude.app/Contents/MacOS/Claude' 2>/dev/null || echo "Claude Desktop is not running"
/usr/sbin/lsof -nP -iTCP 2>/dev/null | grep -iE '^Claude|^claude' | awk '{print $1,$2,$9}' | head -20 || true
echo

echo "== Queued Claude Code telemetry =="
if [[ -d "$HOME/.claude/telemetry" ]]; then
  /usr/bin/find "$HOME/.claude/telemetry" -maxdepth 1 -name '1p_failed_events.*' 2>/dev/null | wc -l | tr -d ' '
else
  echo "no ~/.claude/telemetry"
fi
echo

echo "== Installed files =="
for f in \
  "/etc/pf.anchors/com.user.claude-hiddify" \
  "/etc/claude-hiddify/anthropic4.txt" \
  "/etc/claude-hiddify/anthropic6.txt" \
  "/Library/LaunchDaemons/com.user.claude-hiddify-pf.plist" \
  "/usr/local/sbin/claude-hiddify-pf" \
  "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist" \
  "/Library/Managed Preferences/Administrator/com.anthropic.claudefordesktop.plist" \
  "/Library/Application Support/ClaudeCode/managed-settings.json"; do
  if [[ -e "$f" ]]; then
    ls -l "$f"
  else
    echo "missing: $f"
  fi
done

echo
echo "Ranges: $ANTHROPIC4_CIDR / $ANTHROPIC6_CIDR"
echo "Report complete. Secrets are intentionally omitted."

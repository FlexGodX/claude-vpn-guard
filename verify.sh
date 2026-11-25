#!/bin/bash
#
# Read-only checks for the Claude VPN guard.
#
#   ./verify.sh
#   sudo ./verify.sh
#
# Reads config.env from the project directory (see config.env.example).
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CLAUDE_VPN_CONFIG:-$PROJECT_DIR/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi
: "${VPN_MODE:=auto}"
: "${VPN_NAME:=VPN}"
: "${VPN_PROCESS:=}"
: "${VPN_PROXY_URL:=http://127.0.0.1:12334}"
: "${VPN_EXPECTED_EXIT_IP:=}"
: "${ANTHROPIC_IP:=160.79.104.10}"
: "${ANTHROPIC_PROBE_URL:=https://api.anthropic.com/}"
: "${ANTHROPIC4_CIDR:=160.79.104.0/21}"
: "${ANTHROPIC6_CIDR:=2607:6bc0::/32}"
: "${BLOCK_SENTRY:=1}"
: "${SENTRY_HOSTS:=o1158394.ingest.us.sentry.io}"

ANCHOR="com.user.claude-hiddify"
PFCTL="/sbin/pfctl"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  U="$(stat -f '%Su' /dev/console)"
  H="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
else
  H="$HOME"
fi

route_iface() {
  /sbin/route -n get "$1" 2>/dev/null | /usr/bin/awk '/interface:/{print $2}'
}

process_ok() {
  [[ -z "$VPN_PROCESS" ]] && return 0
  /usr/bin/pgrep -f "$VPN_PROCESS" >/dev/null 2>&1
}

ANTHROPIC_IF="$(route_iface "$ANTHROPIC_IP")"
DEFAULT_IF="$(route_iface default)"
MODE="$VPN_MODE"
if [[ "$VPN_MODE" == "auto" ]]; then
  if [[ "$ANTHROPIC_IF" == utun* ]] && process_ok; then
    MODE="tun"
  else
    MODE="proxy"
  fi
fi

echo "== Config =="
echo "file: $CONFIG_FILE"
echo "vpn: $VPN_NAME"
echo "mode: $MODE (configured: $VPN_MODE)"
echo "process: ${VPN_PROCESS:-<any>}"
echo "proxy: $VPN_PROXY_URL"
echo "Anthropic: $ANTHROPIC_IP ($ANTHROPIC_PROBE_URL)"
echo "route: Anthropic via ${ANTHROPIC_IF:-unknown}, default via ${DEFAULT_IF:-unknown}"
if [[ "$MODE" == "tun" && "$ANTHROPIC_IF" != utun* ]]; then
  echo "WARNING: mode is tun, but Anthropic route is ${ANTHROPIC_IF:-unknown}, not utun*."
fi
if [[ "$MODE" == "proxy" && "$ANTHROPIC_IF" == utun* ]]; then
  echo "WARNING: mode is proxy, but Anthropic is routed via ${ANTHROPIC_IF}."
fi
if ! process_ok; then
  echo "WARNING: configured VPN process '$VPN_PROCESS' is not running."
fi
echo

echo "== System proxy =="
/usr/sbin/scutil --proxy | grep -E 'HTTPEnable|HTTPProxy|HTTPPort|HTTPSEnable|HTTPSProxy|HTTPSPort|SOCKSEnable|SOCKSProxy|SOCKSPort' || true
echo

echo "== VPN path to Anthropic =="
if [[ "$MODE" == "tun" ]]; then
  CODE="$(/usr/bin/curl -4 --noproxy '*' -sS -m 12 -o /dev/null -w '%{http_code}' "$ANTHROPIC_PROBE_URL" 2>/dev/null || true)"
  if [[ -z "$CODE" || "$CODE" == "000" ]]; then
    echo "FAIL: no response through the TUN route ($ANTHROPIC_IF)"
  else
    echo "OK: HTTP $CODE through $VPN_NAME TUN (404 is normal for /)"
  fi
  EXIT_IP="$(/usr/bin/curl -4 --noproxy '*' -sS -m 10 https://api.ipify.org 2>/dev/null || true)"
  echo "Exit IP: ${EXIT_IP:-<no response>}"
else
  CODE="$(/usr/bin/curl -4 -x "$VPN_PROXY_URL" -sS -m 12 -o /dev/null -w '%{http_code}' "$ANTHROPIC_PROBE_URL" 2>/dev/null || true)"
  if [[ -z "$CODE" || "$CODE" == "000" ]]; then
    echo "FAIL: no HTTP response through $VPN_PROXY_URL"
  else
    echo "OK: HTTP $CODE through $VPN_NAME proxy (404 is normal for /)"
  fi
  DCODE="$(/usr/bin/curl -4 --noproxy '*' -sS -m 5 -o /dev/null -w '%{http_code}' "$ANTHROPIC_PROBE_URL" 2>/dev/null || true)"
  if [[ -z "$DCODE" || "$DCODE" == "000" ]]; then
    echo "OK: direct connection blocked"
  else
    echo "WARNING: direct connection returned HTTP $DCODE (pf anchor not loaded?)"
  fi
  EXIT_IP="$(/usr/bin/curl -4 -x "$VPN_PROXY_URL" -sS -m 10 https://api.ipify.org 2>/dev/null || true)"
  echo "Exit IP through $VPN_NAME: ${EXIT_IP:-<no response>}"
fi
if [[ -n "$VPN_EXPECTED_EXIT_IP" ]]; then
  if [[ "${EXIT_IP:-}" == "$VPN_EXPECTED_EXIT_IP" ]]; then
    echo "OK: exit IP matches VPN_EXPECTED_EXIT_IP"
  else
    echo "WARNING: exit IP '${EXIT_IP:-}' != expected '$VPN_EXPECTED_EXIT_IP'"
  fi
fi
echo

echo "== pf anchor =="
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  "$PFCTL" -a "$ANCHOR" -sr 2>/dev/null || echo "anchor $ANCHOR is not loaded"
  echo "-- tables --"
  "$PFCTL" -a "$ANCHOR" -t anthropic4 -T show 2>/dev/null || true
  "$PFCTL" -a "$ANCHOR" -t anthropic6 -T show 2>/dev/null || true
else
  echo "run: sudo $PFCTL -a $ANCHOR -sr"
  echo "run: sudo $PFCTL -a $ANCHOR -t anthropic4 -T show"
fi
echo

echo "== Claude Desktop managed telemetry policy =="
if [[ -f "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist" ]]; then
  /usr/bin/plutil -p "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
else
  echo "MISSING /Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
fi
echo

echo "== Claude Code managed settings =="
if [[ -f "/Library/Application Support/ClaudeCode/managed-settings.json" ]]; then
  cat "/Library/Application Support/ClaudeCode/managed-settings.json"
  if [[ "$MODE" == "tun" ]] && grep -q 'HTTPS_PROXY' "/Library/Application Support/ClaudeCode/managed-settings.json"; then
    echo "WARNING: proxy variables are set while VPN is in TUN mode; Claude Code may fail."
  fi
  if [[ "$MODE" == "proxy" ]] && ! grep -q 'HTTPS_PROXY' "/Library/Application Support/ClaudeCode/managed-settings.json"; then
    echo "WARNING: proxy variables are missing while VPN is in proxy mode; Claude Code may be blocked."
  fi
else
  echo "MISSING /Library/Application Support/ClaudeCode/managed-settings.json"
fi
echo

echo "== Telemetry hosts block =="
if [[ "$BLOCK_SENTRY" == "1" ]]; then
  /usr/bin/awk '/BEGIN claude-hiddify telemetry block/,/END claude-hiddify telemetry block/' /etc/hosts 2>/dev/null || true
  for host in $SENTRY_HOSTS; do
    if /usr/bin/dscacheutil -q host -a name "$host" 2>/dev/null | grep -q '0.0.0.0'; then
      echo "OK: $host -> 0.0.0.0"
    else
      echo "WARNING: $host does not resolve to 0.0.0.0"
    fi
  done
else
  echo "telemetry hosts blocking is disabled in config"
fi
echo

echo "== Anthropic DNS ranges =="
/usr/bin/python3 - "$ANTHROPIC4_CIDR" "$ANTHROPIC6_CIDR" <<'PY'
import ipaddress
import socket
import sys

ranges = [ipaddress.ip_network(sys.argv[1]), ipaddress.ip_network(sys.argv[2])]
for host in ("claude.ai", "api.anthropic.com"):
    try:
        infos = socket.getaddrinfo(host, None)
        ips = sorted({info[4][0] for info in infos})
    except Exception as exc:
        print(f"{host}: DNS error: {exc}")
        continue
    for ip in ips:
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            continue
        inside = any(addr.version == net.version and addr in net for net in ranges)
        print(f"{host}: {ip} {'inside' if inside else 'OUTSIDE (update config/ranges!)'}")
PY
echo

echo "== Queued Claude Code telemetry =="
if [[ -n "${H:-}" && -d "$H/.claude/telemetry" ]]; then
  COUNT="$(/usr/bin/find "$H/.claude/telemetry" -maxdepth 1 -name '1p_failed_events.*' 2>/dev/null | wc -l | tr -d ' ')"
  echo "queued event files: $COUNT"
else
  echo "no ~/.claude/telemetry directory"
fi
echo

echo "== Claude processes =="
/usr/bin/pgrep -fl '/Applications/Claude.app/Contents/MacOS/Claude' 2>/dev/null || echo "Claude Desktop is not running"
/usr/sbin/lsof -nP -iTCP 2>/dev/null | grep -iE '^Claude|^claude' | awk '{print $1,$2,$9}' | head -20 || true
echo
echo "Expected: VPN path OK, direct blocked (proxy mode), exit IP expected, queued telemetry 0."

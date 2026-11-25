#!/bin/zsh
# Optional: quit Claude Desktop after ~60 seconds without a working VPN path.
# It auto-detects TUN vs local proxy:
#   - TUN: Anthropic route is utun* and the optional VPN_PROCESS is alive.
#   - proxy: Anthropic answers through VPN_PROXY_URL.
# Install with extras/install-guard.sh.  Edit the constants below if you
# change the VPN client/port.
set -u

PROXY="${VPN_PROXY_URL:-http://127.0.0.1:12334}"
VPN_PROCESS="${VPN_PROCESS:-HiddifyPacketTunnel}"
PROBE_URL="${ANTHROPIC_PROBE_URL:-https://api.anthropic.com/}"
ANTHROPIC_IP="${ANTHROPIC_IP:-160.79.104.10}"
FAILS=0

vpn_ok() {
  local iface code
  iface="$(/sbin/route -n get "$ANTHROPIC_IP" 2>/dev/null | /usr/bin/awk '/interface:/{print $2}')"
  if [[ "$iface" == utun* ]]; then
    if [[ -n "$VPN_PROCESS" ]] && ! /usr/bin/pgrep -f "$VPN_PROCESS" >/dev/null 2>&1; then
      return 1
    fi
    code="$(/usr/bin/curl -4 --noproxy '*' -sS -m 5 -o /dev/null -w '%{http_code}' "$PROBE_URL" 2>/dev/null || true)"
  else
    code="$(/usr/bin/curl -4 -x "$PROXY" -sS -m 5 -o /dev/null -w '%{http_code}' "$PROBE_URL" 2>/dev/null || true)"
  fi
  [[ -n "$code" && "$code" != "000" ]]
}

while true; do
  if /usr/bin/pgrep -f '/Applications/Claude.app/Contents/MacOS/Claude' >/dev/null 2>&1; then
    if vpn_ok; then
      FAILS=0
    else
      FAILS=$((FAILS + 1))
    fi
    if (( FAILS >= 6 )); then
      /usr/bin/osascript -e 'display notification "Включите VPN, чтобы пользоваться Claude" with title "Claude остановлен"' >/dev/null 2>&1 || true
      /usr/bin/osascript -e 'tell application id "com.anthropic.claudefordesktop" to quit' >/dev/null 2>&1 || true
      sleep 3
      /usr/bin/pkill -TERM -f '/Applications/Claude.app/Contents/MacOS/Claude' >/dev/null 2>&1 || true
      FAILS=0
    fi
  else
    FAILS=0
  fi
  sleep 10
done

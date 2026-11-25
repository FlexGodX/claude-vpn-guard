#!/bin/bash
#
# Claude VPN guard: allow Claude's Anthropic traffic only through the chosen
# VPN (TUN or local HTTP proxy), block direct physical egress, and disable
# Claude Code / Claude Desktop telemetry where the client allows it.
#
# Run as root, with Claude stopped:
#
#   sudo ./install.sh
#
# Per-machine settings live in config.env (gitignored).  See
# config.env.example and README.md.
#
set -euo pipefail

CHECK_ONLY=0
if [[ "${1:-}" == "--check" || "${CHECK_ONLY:-0}" == "1" ]]; then
  CHECK_ONLY=1
fi

if [[ "${EUID:-$(id -u)}" -ne 0 && "$CHECK_ONLY" -ne 1 ]]; then
  echo "This installer must run as root. Use: sudo $0" >&2
  echo "Read-only mode: $0 --check" >&2
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$PROJECT_DIR/files"
CONFIG_FILE="${CLAUDE_VPN_CONFIG:-$PROJECT_DIR/config.env}"
TS="$(date +%Y%m%d-%H%M%S)"

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
: "${PHYSICAL_IFACES:=en0 en1 en2 en3 en4 bridge0}"
: "${BLOCK_SENTRY:=1}"
: "${SENTRY_HOSTS:=o1158394.ingest.us.sentry.io}"

STATE_DIR="/Library/Application Support/ClaudeHiddify"
BACKUP="$STATE_DIR/backup-$TS"

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

route_iface() {
  /sbin/route -n get "$1" 2>/dev/null | /usr/bin/awk '/interface:/{print $2}'
}

process_ok() {
  [[ -z "$VPN_PROCESS" ]] && return 0
  /usr/bin/pgrep -f "$VPN_PROCESS" >/dev/null 2>&1
}

probe_tun() {
  local attempt code=""
  for attempt in 1 2 3; do
    code="$(/usr/bin/curl -4 --noproxy '*' -sS -m 12 -o /dev/null \
      -w '%{http_code}' "$ANTHROPIC_PROBE_URL" 2>/dev/null || true)"
    if [[ -n "$code" && "$code" != "000" ]]; then
      CODE="$code"
      return 0
    fi
    sleep 2
  done
  CODE="$code"
  return 1
}

probe_proxy() {
  local attempt code=""
  for attempt in 1 2 3; do
    code="$(/usr/bin/curl -4 -x "$VPN_PROXY_URL" -sS -m 12 -o /dev/null \
      -w '%{http_code}' "$ANTHROPIC_PROBE_URL" 2>/dev/null || true)"
    if [[ -n "$code" && "$code" != "000" ]]; then
      CODE="$code"
      return 0
    fi
    sleep 2
  done
  CODE="$code"
  return 1
}

check_vpn() {
  if [[ "$MODE" == "tun" ]]; then
    probe_tun
  else
    probe_proxy
  fi
}

flush_dns() {
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
  /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

echo "== Preflight: VPN mode =="
ANTHROPIC_IF="$(route_iface "$ANTHROPIC_IP")"
DEFAULT_IF="$(route_iface default)"
MODE=""

case "$VPN_MODE" in
  auto)
    if [[ "$ANTHROPIC_IF" == utun* ]] && process_ok && probe_tun; then
      MODE="tun"
    elif probe_proxy; then
      MODE="proxy"
    else
      echo "ERROR: no working VPN path to $ANTHROPIC_IP." >&2
      echo "  TUN route: ${ANTHROPIC_IF:-unknown}; process '$VPN_PROCESS' missing or probe failed." >&2
      echo "  Proxy: $VPN_PROXY_URL did not answer." >&2
      echo "Connect the VPN or edit $CONFIG_FILE and retry." >&2
      exit 1
    fi
    ;;
  tun)
    if [[ "$ANTHROPIC_IF" != utun* ]]; then
      echo "ERROR: VPN_MODE=tun but $ANTHROPIC_IP is routed via ${ANTHROPIC_IF:-unknown}, not utun*." >&2
      exit 1
    fi
    if ! process_ok; then
      echo "ERROR: VPN_MODE=tun but process '$VPN_PROCESS' is not running." >&2
      exit 1
    fi
    if ! probe_tun; then
      echo "ERROR: TUN route ${ANTHROPIC_IF} does not answer for $ANTHROPIC_IP." >&2
      exit 1
    fi
    MODE="tun"
    ;;
  proxy)
    if ! probe_proxy; then
      echo "ERROR: VPN_MODE=proxy but $VPN_PROXY_URL does not answer for $ANTHROPIC_IP." >&2
      exit 1
    fi
    MODE="proxy"
    ;;
  *)
    echo "ERROR: VPN_MODE must be auto, tun or proxy (got '$VPN_MODE')." >&2
    exit 1
    ;;
esac

if [[ "$MODE" == "tun" ]]; then
  echo "$VPN_NAME TUN OK (Anthropic via $ANTHROPIC_IF, HTTP $CODE)"
else
  echo "$VPN_NAME proxy OK (HTTP $CODE)"
  PROXY_HOST="${VPN_PROXY_URL#*://}"
  PROXY_HOST="${PROXY_HOST%%:*}"
  PROXY_PORT="${VPN_PROXY_URL##*:}"
  PROXY_PORT="${PROXY_PORT%%/*}"
  if ! /usr/sbin/scutil --proxy | /usr/bin/grep -q "HTTPSProxy.*$PROXY_HOST"; then
    echo "WARNING: system HTTPS proxy is not $PROXY_HOST." >&2
    echo "Claude Desktop needs the system proxy; Claude Code gets it from managed settings." >&2
  fi
  if ! /usr/sbin/scutil --proxy | /usr/bin/grep -q "HTTPSPort.*$PROXY_PORT"; then
    echo "WARNING: system HTTPS proxy port is not $PROXY_PORT." >&2
  fi
fi
echo "Config: $CONFIG_FILE"
echo "Mode: $MODE (VPN: $VPN_NAME; default via ${DEFAULT_IF:-unknown}; Anthropic via ${ANTHROPIC_IF:-unknown})"

# Validate / filter physical interfaces before generating the anchor.
IFACES_PF=""
for iface in $PHYSICAL_IFACES; do
  if /sbin/ifconfig "$iface" >/dev/null 2>&1; then
    IFACES_PF="${IFACES_PF:+$IFACES_PF, }$iface"
  else
    echo "WARNING: physical interface '$iface' not present; skipping." >&2
  fi
done
if [[ -z "$IFACES_PF" ]]; then
  echo "ERROR: none of PHYSICAL_IFACES exists: $PHYSICAL_IFACES" >&2
  exit 1
fi
echo "Physical interfaces blocked: $IFACES_PF"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "CHECK_ONLY: no changes made."
  exit 0
fi

mkdir -p "$BACKUP" "$STATE_DIR" "$TABLE_DIR" /etc/pf.anchors \
  "/Library/Application Support/ClaudeCode" \
  "/Library/Managed Preferences/Administrator" \
  /usr/local/sbin

backup_path() {
  local src="$1"
  [[ -e "$src" ]] || return 0
  local dst="$BACKUP$src"
  mkdir -p "$(dirname "$dst")"
  cp -p "$src" "$dst"
}

# Keep a copy of everything we are about to replace.
backup_path "$PF_CONF"
backup_path "$ANCHOR_FILE"
backup_path "$PLIST_MACHINE"
backup_path "$PLIST_USER"
backup_path "$CC_MANAGED"
backup_path "$DAEMON"
backup_path "$PF_SCRIPT"
backup_path "$HOSTS_FILE"

{
  echo "timestamp=$TS"
  echo "user=${SUDO_USER:-$(stat -f '%Su' /dev/console)}"
  echo "project=$PROJECT_DIR"
  echo "config=$CONFIG_FILE"
  echo "vpn_name=$VPN_NAME"
  echo "mode=$MODE"
  echo "physical_ifaces=$IFACES_PF"
} > "$BACKUP/manifest.txt"

echo "== Installing pf anchor =="
ANCHOR_TMP="$(mktemp /tmp/claude-hiddify-anchor.XXXXXX)"
/usr/bin/sed "s#__IFACES__#$IFACES_PF#g" "$FILES/pf.anchor.template" > "$ANCHOR_TMP"
install -m 644 -o root -g wheel "$ANCHOR_TMP" "$ANCHOR_FILE"
rm -f "$ANCHOR_TMP"

printf '%s\n' "$ANTHROPIC4_CIDR" > "$TABLE_DIR/anthropic4.txt"
printf '%s\n' "$ANTHROPIC6_CIDR" > "$TABLE_DIR/anthropic6.txt"
chown root:wheel "$TABLE_DIR/anthropic4.txt" "$TABLE_DIR/anthropic6.txt"
chmod 644 "$TABLE_DIR/anthropic4.txt" "$TABLE_DIR/anthropic6.txt"

# Add the anchor reference exactly once, before Apple's filter anchor.
if ! /usr/bin/grep -qxF "anchor \"$ANCHOR_NAME\"" "$PF_CONF"; then
  TMP_PF="$(mktemp /tmp/claude-hiddify-pf.XXXXXX)"
  if ! /usr/bin/awk -v line="anchor \"$ANCHOR_NAME\"" '
      $0 == "anchor \"com.apple/*\"" && !done { print line; done=1 }
      { print }
      END { if (!done) exit 2 }
    ' "$PF_CONF" > "$TMP_PF"; then
    echo "ERROR: could not find 'anchor \"com.apple/*\"' in $PF_CONF" >&2
    rm -f "$TMP_PF"
    exit 1
  fi
  if ! "$PFCTL" -n -f "$TMP_PF" >/dev/null 2>&1; then
    echo "ERROR: patched pf.conf failed syntax check" >&2
    rm -f "$TMP_PF"
    exit 1
  fi
  /bin/cat "$TMP_PF" > "$PF_CONF"
  rm -f "$TMP_PF"
fi

if ! "$PFCTL" -n -f "$PF_CONF" >/dev/null 2>&1; then
  echo "ERROR: $PF_CONF failed syntax check; restoring backup" >&2
  cp -p "$BACKUP$PF_CONF" "$PF_CONF"
  exit 1
fi

if ! "$PFCTL" -f "$PF_CONF"; then
  echo "ERROR: could not load $PF_CONF; restoring backup" >&2
  cp -p "$BACKUP$PF_CONF" "$PF_CONF"
  exit 1
fi

if ! "$PFCTL" -a "$ANCHOR_NAME" -f "$ANCHOR_FILE"; then
  echo "ERROR: could not load $ANCHOR_FILE; restoring pf.conf" >&2
  cp -p "$BACKUP$PF_CONF" "$PF_CONF"
  "$PFCTL" -f "$PF_CONF" >/dev/null 2>&1 || true
  exit 1
fi

"$PFCTL" -E >/dev/null 2>&1 || true

echo "== Post-load check =="
if ! check_vpn; then
  echo "ERROR: after loading PF, the VPN path to Anthropic is broken." >&2
  echo "Rolling the PF anchor back so Claude keeps working." >&2
  "$PFCTL" -a "$ANCHOR_NAME" -F all >/dev/null 2>&1 || true
  cp -p "$BACKUP$PF_CONF" "$PF_CONF"
  "$PFCTL" -f "$PF_CONF" >/dev/null 2>&1 || true
  exit 1
fi
echo "$VPN_NAME path still works after PF load (HTTP $CODE)"

echo "== Installing boot-time pf loader =="
install -m 755 -o root -g wheel "$FILES/claude-hiddify-pf" "$PF_SCRIPT"
install -m 644 -o root -g wheel "$FILES/com.user.claude-hiddify-pf.plist" "$DAEMON"
launchctl bootout system/com.user.claude-hiddify-pf >/dev/null 2>&1 || true
launchctl bootstrap system "$DAEMON" >/dev/null 2>&1 || \
  echo "WARNING: launchctl bootstrap failed; rules are loaded now but may not survive reboot" >&2
launchctl kickstart -k system/com.user.claude-hiddify-pf >/dev/null 2>&1 || true

echo "== Installing Claude Desktop managed telemetry policy =="
install -m 644 -o root -g wheel "$FILES/com.anthropic.claudefordesktop.plist" "$PLIST_MACHINE"
install -m 644 -o root -g wheel "$FILES/com.anthropic.claudefordesktop.plist" "$PLIST_USER"
plutil -lint "$PLIST_MACHINE" "$PLIST_USER" >/dev/null
chown root:wheel "$PLIST_MACHINE" "$PLIST_USER"

echo "== Updating /etc/hosts telemetry block =="
TMP_HOSTS="$(mktemp /tmp/claude-hiddify-hosts.XXXXXX)"
/usr/bin/awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '
  $0 == b { skip=1; next }
  $0 == e { skip=0; next }
  !skip { print }
' "$HOSTS_FILE" > "$TMP_HOSTS"
if [[ "$BLOCK_SENTRY" == "1" && -n "$SENTRY_HOSTS" ]]; then
  {
    echo ""
    echo "$HOSTS_BEGIN"
    for host in $SENTRY_HOSTS; do
      echo "0.0.0.0 $host"
    done
    echo "$HOSTS_END"
  } >> "$TMP_HOSTS"
  /bin/cat "$TMP_HOSTS" > "$HOSTS_FILE"
  rm -f "$TMP_HOSTS"
  flush_dns
  echo "blocked: $SENTRY_HOSTS"
else
  /bin/cat "$TMP_HOSTS" > "$HOSTS_FILE"
  rm -f "$TMP_HOSTS"
  flush_dns
  echo "telemetry hosts block disabled/removed"
fi

echo "== Installing Claude Code managed settings ($MODE mode) =="
if [[ "$MODE" == "tun" ]]; then
  MANAGED_SRC="$FILES/managed-settings.tun.json"
  MANAGED_TMP=""
else
  MANAGED_TMP="$(mktemp /tmp/claude-hiddify-managed.XXXXXX)"
  /usr/bin/sed "s#__PROXY_URL__#$VPN_PROXY_URL#g" \
    "$FILES/managed-settings.proxy.json.template" > "$MANAGED_TMP"
  MANAGED_SRC="$MANAGED_TMP"
fi
install -m 644 -o root -g wheel "$MANAGED_SRC" "$CC_MANAGED"
rm -f "${MANAGED_TMP:-}"
if command -v /usr/bin/python3 >/dev/null 2>&1; then
  /usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CC_MANAGED"
else
  plutil -lint "$CC_MANAGED" >/dev/null
fi

# Make cfprefsd notice the managed plist immediately.  Safe; it restarts.
killall cfprefsd >/dev/null 2>&1 || true

echo "== Clearing queued Claude Code telemetry =="
USER_NAME="${SUDO_USER:-$(stat -f '%Su' /dev/console)}"
if [[ -n "$USER_NAME" && "$USER_NAME" != "root" && "$USER_NAME" != "loginwindow" ]]; then
  USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  if [[ -n "${USER_HOME:-}" && -d "$USER_HOME/.claude/telemetry" ]]; then
    rm -f "$USER_HOME/.claude/telemetry/"1p_failed_events.* 2>/dev/null || true
    echo "removed queued telemetry for $USER_NAME"
  fi
fi

echo
echo "== Installed =="
echo "VPN: $VPN_NAME ($MODE)"
echo "Config: $CONFIG_FILE"
echo "Backup: $BACKUP"
echo
echo "pf rules:"
"$PFCTL" -a "$ANCHOR_NAME" -sr || true
echo
echo "Claude Desktop managed policy:"
plutil -p "$PLIST_MACHINE"
echo
echo "Claude Code managed settings:"
cat "$CC_MANAGED"
echo
echo "Start Claude and run $PROJECT_DIR/verify.sh"

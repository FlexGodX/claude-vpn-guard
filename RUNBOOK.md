# RUNBOOK: установка, проверка, смена VPN, откат

Все команды — из корня проекта (`claude-vpn-guard`). `sudo` требует пароль.
Перед установкой закройте Claude: `Cmd+Q` или
`osascript -e 'tell application id "com.anthropic.claudefordesktop" to quit'`.

## 1. Настройка

```bash
cp config.env.example config.env
$EDITOR config.env
```

Минимум, что нужно выбрать:

- `VPN_MODE` — `auto`, `tun` или `proxy`;
- `VPN_NAME` — имя клиента;
- `VPN_PROCESS` — процесс клиента (можно оставить пустым);
- `VPN_PROXY_URL` — если режим proxy;
- `PHYSICAL_IFACES` — физические интерфейсы (обычно `en0 ... bridge0`).

Проверить конфиг без изменений в системе:

```bash
./install.sh --check
```

Ожидаемо: `VPN ... OK`, `Mode: tun|proxy`, список интерфейсов,
`CHECK_ONLY: no changes made`.

## 2. Установка

```bash
sudo ./install.sh
```

Через GUI-запрос пароля:

```bash
osascript -e 'do shell script "/bin/bash '"$PWD"'/install.sh > /tmp/claude-vpn-install.log 2>&1" with administrator privileges'
cat /tmp/claude-vpn-install.log
```

Установщик:

1. проверяет выбранный VPN (TUN-маршрут или proxy) с 3 попытками;
2. фильтрует `PHYSICAL_IFACES` по существующим;
3. генерирует PF anchor из `files/pf.anchor.template`;
4. пишет `ANTHROPIC4_CIDR`/`ANTHROPIC6_CIDR` в `/etc/claude-hiddify/`;
5. добавляет `anchor "com.user.claude-hiddify"` в `/etc/pf.conf`, проверяет
   `pfctl -n`, загружает;
6. проверяет, что после PF выбранный VPN всё ещё отвечает; иначе
   откатывает `pf.conf`;
7. ставит LaunchDaemon;
8. ставит managed plist Claude Desktop и managed settings Claude Code;
9. обновляет `/etc/hosts`-блок Sentry;
10. чистит очередь телеметрии Claude Code.

Бэкап: `/Library/Application Support/ClaudeHiddify/backup-*`.

## 3. Проверка

```bash
./verify.sh
sudo ./verify.sh
```

TUN:

```text
mode: tun
OK: HTTP 404 through <VPN> TUN
Exit IP: <vpn-exit-ip>
pf anchor: block drop ... on en0 ... to <anthropic4>
```

Proxy:

```text
mode: proxy
OK: HTTP 404 through <VPN> proxy
OK: direct connection blocked
```

Проверить, что Claude Desktop идёт через VPN:

```bash
lsof -nP -iTCP | grep -iE '^Claude|^claude'
```

Проверить Claude Code без proxy-переменных (TUN):

```bash
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY -u NO_PROXY \
  claude -p "Reply with exactly: OK"
```

## 4. Тест «без VPN»

Штатно: выключить VPN в интерфейсе клиента, проверить, включить обратно.

```bash
curl -4 --noproxy '*' -m 5 -o /dev/null -w '%{http_code}\n' \
  https://api.anthropic.com/
# 000 / timeout — PF заблокировал прямой выход
```

Не используйте `route change`/kill packet tunnel без необходимости: в нашем
тесте это временно разорвало маршрут, пока VPN не переподключили.

## 5. Сменить VPN-клиент

Меняете только `config.env`, код не трогаете.

### Hiddify TUN

```bash
VPN_MODE=tun
VPN_NAME="Hiddify"
VPN_PROCESS="HiddifyPacketTunnel"
```

Hiddify: режим TUN, системный прокси выключен. Проверка:

```bash
route -n get 160.79.104.10   # interface: utunN
```

### Hiddify proxy

```bash
VPN_MODE=proxy
VPN_NAME="Hiddify"
VPN_PROCESS=""
VPN_PROXY_URL="http://127.0.0.1:12334"
```

Hiddify должен выставлять системный прокси на этот порт.

### Tunnelblick / OpenVPN

```bash
VPN_MODE=tun
VPN_NAME="Tunnelblick"
VPN_PROCESS="Tunnelblick"   # или openvpn
```

Если Tunnelblick — VPN для Claude, разрешите ему default route (или хотя бы
`160.79.104.0/21`). Если он нужен только для корпоративных подсетей, а Claude
должен остаться через Hiddify — оставьте split tunnel и
`VPN_PROCESS=HiddifyPacketTunnel`; Anthropic продолжит идти через Hiddify.
PF блокирует только физические интерфейсы и не различает владельца `utun`.

### WireGuard

```bash
VPN_MODE=tun
VPN_NAME="WireGuard"
VPN_PROCESS="wireguard-go"  # или WireGuard, wg-quick
```

### Любой локальный HTTP proxy

```bash
VPN_MODE=proxy
VPN_NAME="MyVPN"
VPN_PROXY_URL="http://127.0.0.1:7890"
```

После правки:

```bash
./install.sh --check
sudo ./install.sh
```

## 6. Изменить диапазоны/интерфейсы

- диапазоны: `ANTHROPIC4_CIDR`, `ANTHROPIC6_CIDR` в `config.env`;
- интерфейсы: `PHYSICAL_IFACES` в `config.env`;
- Sentry: `BLOCK_SENTRY`, `SENTRY_HOSTS`;
- затем `sudo ./install.sh` (перегенерирует anchor и таблицы).

Вручную только таблицы:

```bash
sudo install -m 644 files/anthropic4.txt /etc/claude-hiddify/anthropic4.txt
sudo install -m 644 files/anthropic6.txt /etc/claude-hiddify/anthropic6.txt
sudo pfctl -a com.user.claude-hiddify -f /etc/pf.anchors/com.user.claude-hiddify
```

## 7. Телеметрия

Claude Code:

```bash
cat "/Library/Application Support/ClaudeCode/managed-settings.json"
find ~/.claude/telemetry -maxdepth 1 -name '1p_failed_events.*' | wc -l
```

Claude Desktop managed plist:

```bash
grep -E 'managedConfig|Managed MDM config' ~/Library/Logs/Claude/main.log | tail
```

Sentry:

```bash
dscacheutil -q host -a name o1158394.ingest.us.sentry.io
# ip_address: 0.0.0.0
```

На Claude Pro (1p) ключи `disableEssentialTelemetry` /
`disableNonessentialTelemetry` имеют область `3p` и не отключают EventLogging.
Sentry блокируется через hosts; полного локального opt-out для 1p нет.

**macOS может удалить вручную положенный plist** из
`/Library/Managed Preferences` после перезагрузки/обновления. В нашем случае
2026-11-25 оба plist исчезли, а PF/hosts/managed settings Claude Code
остались. `verify.sh` покажет `MISSING`; `sudo ./install.sh` вернёт файлы.
На 1p это не влияет на EventLogging, но проверяйте после ребута.

## 8. Диагностика

```bash
./diagnostics/collect.sh > /tmp/claude-vpn-report.txt
sudo ./diagnostics/collect.sh > /tmp/claude-vpn-report.txt
```

PF/anchor:

```bash
sudo pfctl -a com.user.claude-hiddify -sr
sudo launchctl print system/com.user.claude-hiddify-pf | head -30
cat /var/log/claude-hiddify-pf.log
```

`pfctl -s anchors` в macOS 27 не поддерживается.

Если после перезагрузки правил нет:

```bash
sudo launchctl kickstart -k system/com.user.claude-hiddify-pf
cat /var/log/claude-hiddify-pf.log
```

## 9. Откат

```bash
sudo ./uninstall.sh
```

Убирает anchor, LaunchDaemon, managed-файлы, hosts-блок, восстанавливает
managed-файлы из последнего бэкапа. Бэкапы не удаляются.

## 10. Про «Runner»

Hiddify собран Flutter-раннером `Runner`; bundle ID `apple.hiddify.com`,
окно и VPN-сервис — Hiddify. Это тот же клиент. Если хотите имя Hiddify в
Dock, поставьте копию `/Applications/Hiddify.app` с DMG.

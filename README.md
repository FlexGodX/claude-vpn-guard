# Claude VPN guard

Привязка Claude к выбранному VPN-клиенту: прямой выход к Anthropic на
физических интерфейсах блокируется, а Claude Desktop / Claude Code ходят
через TUN или локальный HTTP-прокси **выбранного** VPN. Плюс отключение
телеметрии Claude Code и блокировка Sentry Claude Desktop.

Проект рассчитан на macOS, `pf`, `launchd` и Claude Desktop/Code. Hiddify —
только пример; клиент меняется через `config.env` без правки кода.

## Состав

```text
README.md                 этот файл
SOURCES.md                источники IP/путей/документации
RUNBOOK.md                все команды: установка, проверка, изменение, откат
EVIDENCE.md               что проверено и с каким результатом
config.env.example        шаблон настроек; скопируйте в config.env
.gitignore                config.env и локальные логи не попадают в git
install.sh                установка (root)
uninstall.sh              полный откат (root)
verify.sh                 проверка текущего состояния
files/
  pf.anchor.template      PF-anchor с подстановкой PHYSICAL_IFACES
  anthropic4.txt          160.79.104.0/21
  anthropic6.txt          2607:6bc0::/32
  claude-hiddify-pf       boot-скрипт PF
  com.user.claude-hiddify-pf.plist
  com.anthropic.claudefordesktop.plist
  managed-settings.tun.json
  managed-settings.proxy.json.template
extras/
  claude-hiddify-guard.sh       опционально: закрывать Claude без VPN
  install-guard.sh              установка guard как LaunchAgent
  com.user.claude-hiddify-guard.plist
  com.google.Chrome.plist       опционально: WebRTC без утечки IP
diagnostics/
  collect.sh                    сбор диагностического отчёта
  probe-claude-desktop.md       как найдены managed-ключи/Sentry/EventLogging
evidence/                       локальные (санитизированные) снимки проверок
```

## Быстрый старт

```bash
git clone https://github.com/FlexGodX/claude-vpn-guard.git
cd claude-vpn-guard
cp config.env.example config.env
$EDITOR config.env
sudo ./install.sh
./verify.sh
sudo ./verify.sh
```

`config.env` в git не попадает (`.gitignore`). В нём — режим VPN, имя
процесса/прокси, диапазоны Anthropic и физические интерфейсы.

## config.env

| переменная | смысл |
|---|---|
| `VPN_MODE` | `auto`, `tun` или `proxy` |
| `VPN_NAME` | имя для логов (Hiddify, Tunnelblick, WireGuard, ...) |
| `VPN_PROCESS` | необязательный процесс, который должен быть жив (`pgrep -f`); пусто = не проверять |
| `VPN_PROXY_URL` | локальный HTTP-прокси для `VPN_MODE=proxy` |
| `VPN_EXPECTED_EXIT_IP` | необязательный ожидаемый exit IP для `verify.sh` |
| `ANTHROPIC_IP` | IP для проверки маршрута |
| `ANTHROPIC_PROBE_URL` | URL проверки (`https://api.anthropic.com/`) |
| `ANTHROPIC4_CIDR` / `ANTHROPIC6_CIDR` | блокируемые диапазоны |
| `PHYSICAL_IFACES` | физические интерфейсы для блока (через пробел) |
| `BLOCK_SENTRY` / `SENTRY_HOSTS` | sinkhole Sentry DSN в `/etc/hosts` |

## Как выбрать VPN-клиент

Чтобы Claude пошёл через клиент X, **X должен владеть маршрутом** к
`160.79.104.10` (или default route), а другие TUN-клиенты лучше остановить:
PF не различает владельца `utun`. `VPN_PROCESS` — только проверка, что
процесс жив; `VPN_EXPECTED_EXIT_IP` помогает поймать подмену.

### Hiddify, TUN

```bash
VPN_MODE=tun
VPN_NAME="Hiddify"
VPN_PROCESS="HiddifyPacketTunnel"
```

Hiddify должен быть в режиме TUN (в текущей версии — `utunN`, системный
прокси выключен). Проверка:

```bash
route -n get 160.79.104.10   # interface: utunN
```

### Hiddify, system proxy

```bash
VPN_MODE=proxy
VPN_NAME="Hiddify"
VPN_PROCESS=""               # или Hiddify/Runner, если хотите проверять процесс
VPN_PROXY_URL="http://127.0.0.1:12334"
```

Hiddify должен выставлять системный прокси на этот порт. Claude Code получит
`HTTP_PROXY/HTTPS_PROXY` из managed-настроек; Claude Desktop использует
системный прокси.

### Tunnelblick / OpenVPN

```bash
VPN_MODE=tun
VPN_NAME="Tunnelblick"
VPN_PROCESS="Tunnelblick"    # или openvpn
```

Если Tunnelblick должен быть VPN именно для Claude, разрешите ему маршрут
по умолчанию (или хотя бы `160.79.104.0/21`) через туннель. Если он нужен
только для корпоративных подсетей, а Claude должен остаться через Hiddify —
оставьте split tunnel («Route all IPv4 traffic through the VPN» off) и
`VPN_PROCESS=HiddifyPacketTunnel`: тогда Anthropic продолжит идти через
Hiddify, а Tunnelblick — только корпоративные маршруты.

### WireGuard

```bash
VPN_MODE=tun
VPN_NAME="WireGuard"
VPN_PROCESS="wireguard-go"   # или WireGuard, wg-quick
```

### Любой локальный HTTP-прокси

```bash
VPN_MODE=proxy
VPN_NAME="MyVPN"
VPN_PROXY_URL="http://127.0.0.1:7890"
```

Если клиент умеет только SOCKS, нужен HTTP-фронт (например, `privoxy` или
встроенный mixed-port).

## Важное ограничение: «только выбранный VPN»

PF блокирует Anthropic на `PHYSICAL_IFACES` и разрешает трафик через любой
`utun*` и `lo0`. Поэтому:

- если запущен только выбранный VPN — всё нормально;
- если одновременно подняты два TUN-клиента, трафик пойдёт через тот, чей
  маршрут к `160.79.104.10` победил; PF не умеет различать владельца `utun`;
- `VPN_PROCESS` проверяет, что процесс клиента жив, но не доказывает, что
  маршрут принадлежит именно ему;
- `VPN_EXPECTED_EXIT_IP` в `verify.sh` — простой способ поймать подмену:
  задайте ожидаемый exit IP, и проверка покажет несовпадение.

Для жёсткого «только Hiddify» не запускайте второй TUN-клиент одновременно
или используйте отдельный guard/маршрутную политику. Это ограничение
задокументировано, чтобы не создавать ложное чувство безопасности.

## Что устанавливается

1. **PF anchor** `com.user.claude-hiddify`
   - генерируется из `files/pf.anchor.template` и `PHYSICAL_IFACES`;
   - блокирует `ANTHROPIC4_CIDR` и `ANTHROPIC6_CIDR` на физических
     интерфейсах;
   - `utun*`/`lo0` не блокируются;
   - LaunchDaemon загружает anchor после перезагрузки.

2. **Claude Code managed settings**
   `/Library/Application Support/ClaudeCode/managed-settings.json`
   - TUN: только telemetry-off переменные;
   - proxy: те же + `HTTP_PROXY/HTTPS_PROXY` из `VPN_PROXY_URL`.

3. **Claude Desktop managed plist**
   `/Library/Managed Preferences/com.anthropic.claudefordesktop.plist`
   (`disableEssentialTelemetry`, `disableNonessentialTelemetry`).
   На Claude Pro (1p) эти ключи имеют область `3p` и **не отключают**
   usage analytics; Sentry при этом блокируется через `/etc/hosts`.

4. **Sentry DSN** (`o1158394.ingest.us.sentry.io`) — `0.0.0.0` в `/etc/hosts`.

5. Очередь `~/.claude/telemetry` очищается.

## Проверка

```bash
./verify.sh
sudo ./verify.sh
```

TUN-режим, ожидаемо:

```text
mode: tun
OK: HTTP 404 through <VPN> TUN
Exit IP: <vpn-exit-ip>
pf anchor: block drop ... on en0 ... to <anthropic4>
queued event files: 0
```

Proxy-режим, ожидаемо:

```text
mode: proxy
OK: HTTP 404 through <VPN> proxy
OK: direct connection blocked
```

Тест «без VPN»: выключите VPN в интерфейсе клиента и проверьте, что прямой
`curl` к `https://api.anthropic.com/` не проходит. Не используйте
`route change`/kill packet tunnel без необходимости — см. предупреждение в
`RUNBOOK.md`.

## Телеметрия и IP

- Claude Code: `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`,
  `DISABLE_BUG_COMMAND`, `DO_NOT_TRACK` через managed env.
- Claude Desktop: Sentry DSN заблокирован; managed-ключи читаются, но на 1p
  EventLogging (usage analytics без текста переписки) остаётся. Полного
  локального opt-out для 1p Anthropic не предоставляет.
  macOS может удалить вручную положенный plist из
  `/Library/Managed Preferences` после ребута; `verify.sh` покажет `MISSING`,
  `sudo ./install.sh` вернёт файлы. На 1p это не меняет EventLogging, но
  Sentry-блок в `/etc/hosts` сохраняется.
- IP: VPN маскирует реальный адрес; серверный лог IP на стороне Anthropic
  клиентом не отключается. «Help improve Claude» выключается в настройках
  аккаунта.
- Браузерная веб-версия Claude и WebRTC не покрываются этим проектом; для
  Chrome есть опциональный `extras/com.google.Chrome.plist`.

## Изменить настройки

1. Отредактируйте `config.env`.
2. Перезапустите:

```bash
sudo ./install.sh
```

Код менять не нужно. Диапазоны можно также править в
`files/anthropic4.txt`/`anthropic6.txt` и перезагружать anchor вручную.
Подробные команды — в `RUNBOOK.md`.

## Откат

```bash
sudo ./uninstall.sh
```

Убирает PF anchor, LaunchDaemon, managed-файлы, hosts-блок и восстанавливает
предыдущие managed-файлы из
`/Library/Application Support/ClaudeHiddify/backup-*`.

## Опционально: закрывать Claude без VPN

```bash
./extras/install-guard.sh
```

Guard сам определяет TUN/proxy, ждёт ~60 секунд без рабочего пути и закрывает
Claude. Настройки — константы в `extras/claude-hiddify-guard.sh` (прокси,
процесс, probe URL).

## Про «Runner»

Если Hiddify отображается как `Runner` — это внутреннее имя его Flutter-
раннера. Bundle ID `apple.hiddify.com`, окно и VPN-сервис — Hiddify. Это тот
же клиент, не отдельное приложение.

## Источники

- `SOURCES.md`: ARIN/whois, Apple `pf.conf`/`pfctl`, Hiddify/sing-box,
  Claude Code docs, локальное исследование `app.asar`.
- `EVIDENCE.md` и `evidence/`: whois, правила PF, проверки, ограничения.
- `RUNBOOK.md`: все команды, включая установку через `osascript` и
  диагностику.

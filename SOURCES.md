# Источники и происхождение данных

Проект собран под конкретную машину (macOS 27, Hiddify 5.5.5, Claude Desktop
5.11492.5). Ниже — что именно использовалось, где это проверить и какие
локальные артефакты приложены.

## 1. IP-диапазоны Anthropic

Anthropic, PBC владеет:

- IPv4: `160.79.104.0/21` (`160.79.104.0`–`160.79.111.255`)
- IPv6: `2607:6bc0::/32`

Проверка:

```bash
whois 160.79.104.10 | grep -Ei 'NetRange|CIDR|OrgName|Organization'
whois 2607:6bc0::10 | grep -Ei 'NetRange|CIDR|OrgName|Organization'
```

Публичный ARIN REST (может быть недоступен из-за VPN/фильтра):

```text
https://whois.arin.net/rest/org/AP-2440/nets
```

Локальные копии вывода: `evidence/arin-anthropic-ipv4.txt`,
`evidence/arin-anthropic-ipv6.txt`.

## 2. PF на macOS

Использованы штатные `pf.conf(5)`, `pfctl(8)` и anchor-механизм macOS:

```bash
man pf.conf
man pfctl
cat /etc/pf.conf
pfctl -n -f /etc/pf.conf       # синтаксическая проверка
```

Ключевые вещи:

- `anchor "com.user.claude-hiddify"` в `/etc/pf.conf`;
- отдельный anchor-файл `/etc/pf.anchors/com.user.claude-hiddify`;
- `table <anthropic4> persist file ...`;
- `block drop out quick on { en0, ... } inet from any to <anthropic4>`;
- LaunchDaemon для восстановления после перезагрузки.

Официальной документации Apple с примерами именно такого anchor нет; синтаксис
проверялся `pfctl -n` и загрузкой на этой машине. См. `evidence/pf-rules.txt`.

## 3. Hiddify / sing-box

- Hiddify app: `https://github.com/hiddify/hiddify-app`
- sing-box route/DNS: `https://sing-box.sagernet.org/configuration/route/`
- Локально: Hiddify `5.5.5 (50505)`, bundle `apple.hiddify.com`,
  приложение запускается как Flutter-раннер `Runner` (внутреннее имя).
- Конфиг Hiddify: `~/Library/Application Support/apple.hiddify.com/`
  (`data/current-config.json`, `data/box.log`, `app.log`).
- В текущем режиме — **TUN**: default route через `utunN`, exit IP Hiddify.
  Профиль и VLESS-параметры в этот репозиторий **не включены** (секреты).

Сводка без секретов: `evidence/hiddify-summary.md`.
Санитизированный inbounds/route/dns: `evidence/hiddify-route-sanitized.json`
(без outbounds/VLESS UUID/Clash secret).

## 4. Claude Code

Официальные документы (могут переехать, проверяйте актуальный URL):

- Settings: `https://docs.anthropic.com/en/docs/claude-code/settings`
- Environment variables:
  `https://docs.anthropic.com/en/docs/claude-code/environment-variables`
- Managed settings на macOS:
  `/Library/Application Support/ClaudeCode/managed-settings.json`

Использованные переменные:

- `DISABLE_TELEMETRY=1`
- `DISABLE_ERROR_REPORTING=1`
- `DISABLE_BUG_COMMAND=1`
- `DO_NOT_TRACK=1`
- в proxy-режиме дополнительно `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`

Проверка на этой машине: `claude -p "Reply with exactly: OK"` без
proxy-переменных вернул `OK` (TUN-режим), очередь
`~/.claude/telemetry/1p_failed_events.*` — `0`.

## 5. Claude Desktop

Публичной документации на управление телеметрией 1p-клиента через локальный
plist нет; использовалось локальное исследование установленного приложения:

- `/Applications/Claude.app` версия `5.11492.5`;
- `/Applications/Claude.app/Contents/Resources/app.asar`;
- managed plist:
  `/Library/Managed Preferences/com.anthropic.claudefordesktop.plist`;
- ключи `disableEssentialTelemetry`, `disableNonessentialTelemetry`;
- в коде приложения эти ключи имеют `support.enabled.scopes: ["3p"]`,
  то есть предназначаны для third-party-развёртываний. На аккаунте Claude Pro
  (1p) приложение читает plist (`type: 'managed'` в логе), но не отключает
  usage analytics (EventLogging). Это ограничение зафиксировано в
  `EVIDENCE.md` и `README.md`.

Sentry DSN, взятый из локального `app.asar`:

```text
o1158394.ingest.us.sentry.io
```

Он заблокирован через `/etc/hosts` (см. `evidence/sentry-hosts.txt`).

## 6. macOS-утилиты

- `scutil --nc list/status/start` — управление VPN-сервисом;
- `route -n get` / `netstat -rn` — проверка маршрутов;
- `curl --noproxy '*'` и `curl -x` — проверка путей;
- `dig` — проверка A/AAAA;
- `launchctl bootstrap/kickstart` — LaunchDaemon/LaunchAgent;
- `plutil -lint` — plist;
- `osascript ... with administrator privileges` — установка с правами root.

## 7. Локальные доказательства

- `evidence/install-log.txt` — лог успешной установки;
- `evidence/pf-rules.txt` — загруженные правила;
- `evidence/verify-output.txt` — вывод `verify.sh`;
- `evidence/claude-connections.txt` — соединения Claude через `utunN`;
- `evidence/claude-managed-config.log` — чтение managed plist;
- `evidence/sentry-hosts.txt` — блокировка Sentry;
- `evidence/route-test.txt` — проверка «без Hiddify» (и предупреждение);
- `evidence/eventlogging-1p.md` — почему EventLogging остаётся.

Все секреты (VLESS UUID, адрес/пароль профиля, Clash API secret, account/org
UUID, OAuth-токены) из evidence удалены.

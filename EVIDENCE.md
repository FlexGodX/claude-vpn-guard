# EVIDENCE: что проверено на этой машине

Дата проверки: 2026-11-19. Окружение: macOS 27.0 (26A428), Hiddify 5.5.5,
Claude Desktop 5.11492.5, Claude Code 2.1.326/2.1.328.

## 1. Hiddify и маршруты

В рабочем состоянии Hiddify был в TUN-режиме:

```text
route get default      -> utunN
route get 160.79.104.10 -> utunN
scutil --nwi           -> utunN <tun-local-ip>, VPN server ::1
curl --noproxy '*' https://api.ipify.org -> <vpn-exit-ip>
```

Прямой IP без Hiddify (когда туннель был выключен) — `<direct-ip>`.
Это подтверждает, что Hiddify действительно меняет выходной адрес.

## 2. PF-блок

После установки загружены правила:

```text
block drop out quick on en0 inet from any to <anthropic4>
block drop out quick on en1 inet from any to <anthropic4>
...
block drop out quick on bridge0 inet6 from any to <anthropic6>
```

Таблицы:

```text
160.79.104.0/21
2607:6bc0::/32
```

Проверка при включённом Hiddify:

```text
curl -4 --noproxy '*' https://api.anthropic.com/
HTTP 404, remote_ip 160.79.104.10
```

404 — нормальный ответ корня API; главное, соединение проходит.

Проверка «без Hiddify»: во время теста туннель был временно отключён
(мы делали `route change` и kill packet tunnel — это **не** штатный способ,
он временно сломал маршрут). После отключения:

```text
route get default -> en0 (192.168.31.1)
curl --noproxy '*' -m 6 https://api.anthropic.com/ -> timeout (000)
```

То есть прямой выход к Anthropic блокируется, Claude без Hiddify не может
работать. После ручного reconnect Hiddify маршрут `utunN` восстановился,
`curl` снова вернул 404. Этот тест подтверждает и блок, и то, что после
переподключения Hiddify всё восстанавливается.

## 3. Claude Desktop

Claude Desktop после запуска (TUN-режим):

```text
Claude <pid> <tun-local-ip>:64000->160.79.104.10:443
Claude <pid> <tun-local-ip>:64008->160.79.104.10:443
Claude <pid> <tun-local-ip>:64074->160.79.104.10:443
```

Прямых соединений к Anthropic через внешний IP нет; соединения к Anthropic
идут через адрес TUN `<tun-local-ip>`. Другие соединения Claude (плагины,
feature-сервисы) также видны через utun и не являются прямым выходом к
Anthropic.

Managed plist прочитан:

```text
[managedConfig] configuration at launch { type: 'managed', remote: false,
  managedKeys: [ 'disableEssentialTelemetry', 'disableNonessentialTelemetry' ] }
Managed MDM config detected { keys_set: [...], machine_plist: 'read',
  user_plist: 'read', supplied_keys: [] }
```

Sentry DSN заблокирован:

```text
/etc/hosts:
  0.0.0.0 o1158394.ingest.us.sentry.io
dscacheutil: ip_address: 0.0.0.0
curl https://o1158394.ingest.us.sentry.io/ -> Failed to connect (000)
```

## 4. Claude Code

Проверка без proxy-переменных (TUN-режим):

```text
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY -u NO_PROXY \
  claude -p "Reply with exactly: OK"
OK
```

Очередь телеметрии:

```text
find ~/.claude/telemetry -maxdepth 1 -name '1p_failed_events.*' | wc -l
0
```

## 5. Ограничение телеметрии Claude Desktop (важно)

Managed-ключи Claude Desktop (`disableEssentialTelemetry`,
`disableNonessentialTelemetry`) в коде приложения имеют:

```text
support: { enabled: { scopes: ["3p"] } }
```

То есть это настройки для third-party (3p) развёртываний. На аккаунте
Claude Pro (1p) они читаются (см. лог выше), но EventLogging продолжает
пытаться отправлять батчи. В логе были строки:

```text
[EventLogging] Flushing 50 events
[EventLogging] Batch flush FAILED: ... status: 403 ...
```

Содержимое переписки в эти события не входит (по описанию приложения —
usage analytics). Sentry при этом заблокирован через hosts. Полного
локального opt-out для 1p-телеметрии Anthropic не предоставляет; это
ограничение, а не недоделка установщика. См. `evidence/eventlogging-1p.md`.

## 6. Что не проверялось

- Перезагрузка Mac с автоматическим восстановлением PF/LaunchDaemon:
  LaunchDaemon установлен и `launchctl print` проверялся, но полный reboot
  не выполнялся.
- Другие Anthropic-клиенты (Cursor/Cline/SDK): PF блокирует их прямой выход;
  они должны ходить через Hiddify.
- Браузерная телеметрия claude.ai (веб-приложение) и WebRTC: не отключались;
  для Chrome есть опциональный plist `extras/com.google.Chrome.plist`.
- Полный opt-out 1p-телеметрии Claude Desktop: недоступен локально.

## 7. Инцидент при тесте

Во время проверки PF мы временно изменили маршрут `160.79.104.10` на `en0`
и убили packet tunnel, чтобы проверить блок. Это привело к временной потере
маршрута Hiddify. Пользователь переподключил Hiddify, маршрут `utunN`
восстановился, проверки снова прошли. В RUNBOOK этот способ помечен как
небезопасный; штатный тест — выключить/включить VPN в интерфейсе Hiddify.

## 8. Managed plist исчез после ребута

2026-11-25 оба файла
`/Library/Managed Preferences/com.anthropic.claudefordesktop.plist` и
`/Library/Managed Preferences/Administrator/com.anthropic.claudefordesktop.plist`
отсутствовали, хотя PF anchor, `/etc/hosts`-блок и managed settings Claude
Code остались. Похоже, macOS удаляет вручную положенные managed preferences
после перезагрузки/обновления, если они не пришли из MDM. `verify.sh` в этом
случае пишет `MISSING`; `sudo ./install.sh` возвращает файлы. На Claude Pro
(1p) эти ключи всё равно не отключают EventLogging, а Sentry остаётся
заблокированным через `/etc/hosts`, поэтому фактическая защита не пропала.

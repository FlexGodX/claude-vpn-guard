# Как были найдены настройки Claude Desktop

Все команды — локально на этой машине; приложение не модифицировалось.
Версия: Claude Desktop `5.11492.5`, путь `/Applications/Claude.app`.

## 1. Managed-конфигурация

Поиск путей и ключей в `app.asar`:

```bash
python3 - <<'PY'
p='/Applications/Claude.app/Contents/Resources/app.asar'
data=open(p,'rb').read()
for term in (b'/etc/claude-desktop', b'managed-settings.json',
             b'disableEssentialTelemetry', b'disableNonessentialTelemetry'):
    print(term, data.count(term))
    i=data.find(term)
    if i >= 0:
        print(data[max(0,i-400):i+500].decode('utf-8','replace'))
PY
```

Найденные факты:

- macOS читает managed plist из:
  `/Library/Managed Preferences/com.anthropic.claudefordesktop.plist`
  и `/Library/Managed Preferences/<user>/com.anthropic.claudefordesktop.plist`.
- ключи: `disableEssentialTelemetry`, `disableNonessentialTelemetry`.
- в схеме настроек у них `support.enabled.scopes: ["3p"]`, поэтому на
  Claude Pro (1p) они читаются, но не отключают usage analytics.
- Sentry DSN: `o1158394.ingest.us.sentry.io`.

Проверка чтения plist в логе:

```bash
grep -E 'managedConfig|Managed MDM config' ~/Library/Logs/Claude/main.log | tail
```

## 2. EventLogging

Поиск endpoint:

```bash
strings -a /Applications/Claude.app/Contents/Resources/app.asar \
  | grep -aoE '.{0,120}event_logging.{0,160}' | head
```

Найдено:

- POST на `${base}/api/event_logging/v2/batch` (base — `https://claude.ai`);
- очередь `EventLogging` в main-процессе;
- проверка `if (!q().telemetry.disableNonessential) return "off"` —
  то есть ключ должен попасть в итоговую конфигурацию, а на 1p он
  отфильтрован областью `3p`.
- в логах: `[EventLogging] Flushing N events` и
  `Batch flush FAILED ... status: 403` (не все запросы принимаются).

## 3. Sentry

Домен DSN найден в `app.asar`. Блокировка проверяется так:

```bash
dscacheutil -q host -a name o1158394.ingest.us.sentry.io
curl -sS -m 5 -o /dev/null -w '%{http_code}\n' \
  https://o1158394.ingest.us.sentry.io/
```

Ожидаемо: `0.0.0.0` и `000` (соединение не проходит).

## 4. Ограничение

Это локальное исследование установленного приложения, а не публичный API
Anthropic. Ключи/пути могут измениться в новых версиях Claude Desktop;
после обновления проверьте `verify.sh` и лог `managedConfig`.

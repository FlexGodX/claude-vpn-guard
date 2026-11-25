# Почему EventLogging Claude Desktop остаётся на Pro (1p)

В `app.asar` Claude Desktop (5.11492.5) ключи телеметрии описаны так:

```text
disableEssentialTelemetry:
  readers: ["desktop","code"]
  support.enabled.scopes: ["3p"]

disableNonessentialTelemetry:
  readers: ["desktop","code"]
  support.enabled.scopes: ["3p"]
```

`3p` — third-party deployment. На аккаунте Claude Pro (1p) приложение
читает plist (лог `managedConfig ... type: 'managed'`), но EventLogging
продолжает пытаться отправлять батчи:

```text
[EventLogging] Flushing 50 events
[EventLogging] Batch flush FAILED: ... status: 403 ...
```

Содержимое переписки в эти события не входит (по описанию приложения —
usage analytics). Полного локального opt-out для 1p-телеметрии Anthropic
не предоставляет; это не ошибка установщика.

Что сделано:

- Claude Code: телеметрия выключена managed env-переменными.
- Claude Desktop Sentry DSN: заблокирован через `/etc/hosts`.
- Managed plist с ключами установлен; он пригодится, если аккаунт/режим
  станет 3p, но на 1p не отключает EventLogging.

Что можно сделать дополнительно (по желанию, с риском для фич):

- заблокировать Statsig/featuregates в `/etc/hosts` или Hiddify;
- использовать более инвазивный MITM/патч приложения;
- выключить «Help improve Claude» в настройках аккаунта (серверная настройка,
  не проверяется локально).

# Evidence index

Все файлы — локальные снимки проверок на машине 2026-11-19. Секреты
(Hiddify VLESS UUID/сервер, Clash secret, Claude account/org UUID, токены)
удалены или не включались.

| файл | что показывает |
|---|---|
| `arin-anthropic-ipv4.txt` | whois: Anthropic 160.79.104.0/21 |
| `arin-anthropic-ipv6.txt` | whois: Anthropic 2607:6bc0::/32 |
| `install-log.txt` | успешная установка: preflight TUN, PF, managed, hosts |
| `pf-rules.txt` | загруженные правила блокировки и таблицы |
| `verify-output.txt` | текущий вывод `verify.sh` |
| `claude-connections.txt` | Claude Desktop ходит через <tun-local-ip> (utunN) |
| `claude-managed-config.log` | Claude Desktop прочитал managed plist |
| `sentry-hosts.txt` | Sentry DSN резолвится в 0.0.0.0, соединение не проходит |
| `route-test.txt` | проверка «без Hiddify» и временный инцидент с маршрутом |
| `eventlogging-1p.md` | почему 1p EventLogging нельзя полностью отключить локально |
| `hiddify-summary.md` | режим/маршруты Hiddify без секретов |
| `hiddify-route-sanitized.json` | inbounds/route/dns Hiddify без VLESS-секретов |

Команды для воспроизведения — в `../RUNBOOK.md`, ссылки на источники — в
`../SOURCES.md`.

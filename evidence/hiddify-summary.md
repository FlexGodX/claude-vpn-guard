# Hiddify: сводка без секретов

Значения ниже — пример с машины автора; exit IP/локальный адрес будут
другими. Секреты профиля не включены.

- Версия: 5.5.5 (50505), macOS build `apple.hiddify.com`.
- Режим: TUN (`flutter.service-mode = vpn`).
- Интерфейс: `utunN`, локальный адрес `<tun-local-ip>`, IPv6 `<tun-local-ipv6>`.
- Default route: `utunN`.
- Exit IP через Hiddify: `<vpn-exit-ip>`.
- Прямой IP без Hiddify: `<direct-ip>`.
- System proxy в TUN-режиме выключен (`HTTPEnable: 0`).
- Локальный mixed-proxy `127.0.0.1:12334` появляется в proxy-режиме
  (`set_system_proxy: true` в inbound Hiddify).

Маршрутные правила sing-box/Hiddify, релевантные для Claude (из
`data/current-config.json`, без секретов):

- IPv6 `reject` (первое правило);
- `sniff`;
- DNS hijack;
- private/local CIDR -> `direct`;
- `geosite-ru`, `geoip-ru` -> `direct`;
- `final: select` (то есть остальное, включая Anthropic, идёт через
  выбранный VLESS outbound).

Профиль VLESS, UUID, адрес сервера и Clash API secret в этот репозиторий
намеренно не включены.

Файлы Hiddify:

- `~/Library/Application Support/apple.hiddify.com/data/current-config.json`
- `~/Library/Application Support/apple.hiddify.com/data/box.log`
- `~/Library/Application Support/apple.hiddify.com/app.log`
- `~/Library/Preferences/apple.hiddify.com.plist`

Особенность отображения: приложение собрано Flutter-раннером с именем
`Runner`; в WindowServer/Activity Monitor процесс может называться Runner,
но bundle id — `apple.hiddify.com`, заголовок окна — Hiddify, VPN-сервис —
Hiddify.

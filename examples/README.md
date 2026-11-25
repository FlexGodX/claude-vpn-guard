# Example configs

Copy one over `config.env`, adjust names/ports/interfaces, then run
`./install.sh --check` and `sudo ./install.sh`.

- `hiddify-tun.env` — Hiddify TUN/VPN mode.
- `hiddify-proxy.env` — Hiddify system proxy on 127.0.0.1:12334.
- `tunnelblick.env` — Tunnelblick/OpenVPN owns the Anthropic route.
- `wireguard.env` — WireGuard TUN.

Important: the selected client must own the route to `160.79.104.10`. PF
blocks only physical interfaces and cannot tell two TUN clients apart. If you
run Hiddify for Claude and Tunnelblick for corporate subnets, keep
Tunnelblick split and leave `VPN_PROCESS="HiddifyPacketTunnel"`.

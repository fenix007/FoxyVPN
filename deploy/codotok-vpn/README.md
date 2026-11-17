# Private VPN on the Codotok VPS

Standalone service on `codotok@5.253.63.18` in `/home/codotok/vpn`.
It uses sing-box Shadowsocks 2022 (`2022-blake3-aes-256-gcm`) on TCP 18443.
It does not change Codotok's Caddy, app deployment, SQLite or API settings.

`initialize.py` generates a dedicated random 256-bit key on the VPS. Server and
client files are created mode 0600 in the private deployment directory. Never
commit either `server.json` or `codotok-vpn.foxyvpn.json`. The generated profile
contains the VPN key; provide it only to the intended user through authenticated
BB downloads or another private channel. It is independent of Codotok API keys.

Deployment: copy `compose.yaml` and `initialize.py` to the directory, run the
initializer once, set `VPN_IMAGE` in `.env` to the reviewed immutable
`ghcr.io/sagernet/sing-box@sha256:...` image, then run:

```sh
docker compose run --rm --no-deps vpn check -c /etc/sing-box/config.json
docker compose up -d vpn
docker compose ps
```

The container runs as the deployment user without capabilities, uses a read-only
filesystem, and has memory/CPU/PID/log limits. Requests to private addresses,
metadata ranges, the VPS's own IP and SMTP ports are rejected after resolving
hostnames. It publishes a dedicated encrypted endpoint, with no unauthenticated
SOCKS or management API.

In the updated FoxyVPN for macOS, select **Свой сервер → Импортировать сервер…**
and choose `codotok-vpn.foxyvpn.json`. Firefox sign-in is not required. The profile
selects full VPN with Russian zones direct; edit **Маршрутизация** for individual
exceptions or the Claude/Codex-only mode. VPN traffic currently supports TCP/DNS.

The profile is stored in the macOS Keychain. During a connection, the client
creates a mode-0600 relay config inside a mode-0700 run directory. Only a local
SOCKS port and validated routing settings go to the privileged TUN helper.

To stop this VPN alone: `docker compose stop vpn` from `/home/codotok/vpn`.
To revoke a leaked profile, stop this service and explicitly rotate its dedicated
VPN key in both the server and client profile; do not change API credentials.

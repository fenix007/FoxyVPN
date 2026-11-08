# Third-party components used by the macOS build

`macos/scripts/prepare-backends.sh` downloads source and toolchain material into
the ignored `macos/.build` directory. The generated binaries are intended for a
local build of FoxyVPN.

## firefox-vpn-client

- Source: <https://github.com/UjuiUjuMandan/firefox-vpn-client>
- Pinned revision: `55ad91a2ccea1c93e69c82a08a7681e279884db5`
- Local changes: `macos/Backend/firefox-vpn-client-macos.patch`
- Purpose: Firefox Account, Guardian, server-directory, HTTP/2/HTTP/3 CONNECT,
  and local SOCKS5 protocol backend.

The pinned upstream revision does not contain a license file or license notice.
The preparation script builds it from source for local use. Do not redistribute
that component until its license and redistribution terms have been clarified
with its author.

## sing-box

- Source: <https://github.com/SagerNet/sing-box>
- Version: `1.14.4`
- Pinned revision: `c005f35300ce76427dc285481ec5695f5b179cd2`
- Purpose: macOS TUN-to-SOCKS routing process.
- License: GNU General Public License v3.0 or later; see the upstream repository.

## Go toolchain

- Source: <https://go.dev/dl/>
- Version: `1.27.3` for macOS arm64
- Archive SHA-256: `dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2`
- License: BSD-style Go license; see <https://go.dev/LICENSE>.

Transitive Go modules and their versions are fixed by the upstream `go.mod` and
`go.sum` files. Their individual notices remain in the downloaded module cache.

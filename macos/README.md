# FoxyVPN for macOS

Native SwiftUI client for Apple Silicon Macs running macOS 14 or newer. This is
an initial desktop port alongside the Android application. It uses the same
Firefox Accounts / Mozilla Guardian service and an HTTP/2 CONNECT transport.

## Build and install on this Mac

Requires Apple's Command Line Tools (`xcode-select --install`); a full Xcode,
Android Studio, Java and Homebrew are not required.

From the repository root:

```sh
macos/scripts/build-app.sh --install
open "$HOME/Applications/FoxyVPN.app"
```

The script builds the native app, downloads a checksum-verified local Go
compiler, fetches pinned backend sources and builds them. Go and the backend
sources stay under the ignored `macos/.build` directory. The application bundle
is also available at `macos/dist/FoxyVPN.app`. Installation refuses to overwrite
an existing app; quit it and move the previous bundle aside before reinstalling.
For an existing native Go installation, set `FOXYVPN_GO_BIN` to its executable.

The local build is ad-hoc signed. It is intended for this machine, and is not a
notarized public release. Third-party source revisions and notices are in
[THIRD_PARTY.md](THIRD_PARTY.md).

## Connect

1. Open FoxyVPN and click **Войти…**. Sign in on the Firefox Accounts page,
   including email confirmation or two-factor authentication if requested.
   Keep the sign-in window open until it closes automatically: the app checks
   Mozilla's session status before accepting the sign-in. Verifying an email
   address alone does not necessarily confirm the current session.
   Enter your full email address and your **Mozilla account password**. A Gmail
   address is supported, but the Google password is not the Mozilla password.
   Google/Apple sign-in is not supported by this initial port's Sync WebChannel
   login flow. If your Mozilla account was created through Google or Apple,
   set a Mozilla password yourself at <https://accounts.firefox.com/settings>
   before using this client. Mozilla documents the Sync limitation in its
   [third-party sign-in guide](https://support.mozilla.org/en-US/kb/sign-in-accounts-using-3rd-party-auth).
2. Choose a country from Mozilla's live server directory.
3. Click **Подключить VPN**. The app first establishes and tests the upstream
   connection. macOS then asks for administrator authorization to create the
   TUN interface and routes.
4. **Отключить VPN** stops the connection. Closing the window keeps it in the
   menu bar; quitting the application stops it.

The account must have access to Firefox VPN. Mozilla determines regional
availability, entitlement and traffic quota. A successful build does not grant
service access. Authentication and a live VPN connection require your account;
no credentials are supplied by this repository.

## Current scope

- Traffic statistics show received/sent bytes and speed for the current (or last)
  connection, plus a total saved across app restarts. Counting starts with this
  version and uses the TUN interface's 64-bit counters, including packet headers.
  Traffic that bypasses the TUN is not counted; these are not Mozilla quota figures.
- IPv4 and IPv6 TCP traffic uses the macOS TUN interface.
- DNS queries are intercepted and resolved using HTTPS through the proxy.
- UDP other than DNS is rejected. QUIC can fall back to TCP in browsers;
  UDP-only games, voice calls and other UDP applications are not supported.
- Local network traffic bypasses the VPN.
- Firefox control-plane traffic and the upstream transport bypass the tunnel
  to avoid recursively sending the VPN connection into itself. Its service
  DNS names use a separate direct HTTPS resolver.
- There is no persistent kill switch. Disconnecting or losing the application
  restores normal routing. Other VPN clients can override routes; avoid running
  multiple full-tunnel VPNs simultaneously when testing this port.
- Known DNS limitation: an existing macOS encrypted DNS connection can remain
  bound to the physical interface across VPN connections or country changes.
  This was observed with the system resolver using Google DNS over QUIC.
  Port 53 interception does not cover that connection. DNS leak protection is
  incomplete; a different DNS country alone does not establish the route.
- Android-only features such as per-app split tunneling and tiles are not
  available in the initial Mac client.

## Sites that bypass the VPN

Open **Сайты без VPN → Настроить…** in the main window. You can enable direct
connections for `.ru`, `.su`, and `.рф` and add your own domain names, IP addresses,
or IPv4/IPv6 CIDR ranges, one per line. A domain includes its subdomains. Use
`example.com`, not a URL with `https://` or a path. Plain domain lists, comments
starting with `#`, and `domain:example.com` entries are accepted. The list is
limited to 2,048 entries and 32 KB.

**Добавить список UnRKN** downloads a pinned plain domain list from
[UnRKN/ru-blocklist](https://github.com/UnRKN/ru-blocklist/tree/155441a59bbe913f9ef494cc67e909c3d88ad326)
into the editor. Review
the entries, then click **Сохранить**. The app does not download this list in the
background or silently replace your exceptions. The source revision is pinned
in the app; updating the repository does not change your routing rules. You can
paste newer domain lists manually. Imported entries merge with existing entries.
Single-label domains such as `com` are rejected; use the explicit zone toggle
for `.ru`, `.su`, and `.рф`.

Settings are saved on this Mac and take effect on the next VPN connection.
Other traffic continues through the VPN. DNS for excluded domains uses the
direct HTTPS resolver; DNS for other domains continues through the proxy.
Local network bypass remains enabled. Routing exceptions do not add UDP proxying.
Enabling an entire domain zone also bypasses the VPN for blocked sites in that
zone; disable the zone toggle and use individual domains if needed.

Domain rules use DNS mapping and protocol sniffing. An application's private
encrypted DNS, encrypted TLS names, or a previously cached address can prevent
the domain from being identified. If an exception does not match, restart the
application making the connection or use a specific IP/CIDR exception.

For Happ, [RoscomVPN Routing](https://github.com/hydraponique/roscomvpn-routing)
provides ready profiles. They include broader direct/proxy/block rules; FoxyVPN
does not import those complete profiles or their binary geosite databases.

## Processes and credentials

`FoxyVPN.app` contains a SwiftUI/WebKit frontend, the pinned Firefox protocol
backend (`foxyvpn-proxy`), stock `sing-box` as a TUN-to-SOCKS bridge, and a small
privileged supervisor (`foxyvpn-tunnel`). Android's customized `libbox.aar` is
not used on macOS.

The sign-in bridge only accepts session tokens from the main frame at the
HTTPS `accounts.firefox.com` origin. Its WebKit website store is ephemeral.
OAuth credentials are persisted in the macOS Keychain. While connected, the
Go backend needs a temporary credential file in a private directory under
`~/Library/Application Support/FoxyVPN` (directory mode 0700, file mode 0600).
Refreshed credentials are copied to the Keychain. Runtime files are removed
on disconnect, and stale runtime directories are removed before the next
connection. Tokens are never passed as command-line arguments.

The administrator prompt copies only the TUN executable and supervisor to a
fresh root-owned staging directory. The supervisor validates the restricted
domain/IP settings, generates its own configuration and watches the application
and unprivileged backend. It stops
the TUN process if either exits. The backend also watches its parent process.
No launch agent, login item, persistent privileged daemon or system proxy
setting is installed.

## Verification

```sh
macos/scripts/test.sh
macos/scripts/build-app.sh
macos/dist/FoxyVPN.app/Contents/MacOS/FoxyVPN --self-test
```

The dependency preparation script also runs the protocol backend's Go tests.
Configuration checks and unit tests do not demonstrate Mozilla account access.
To test end to end, sign in, authorize the tunnel, check the exit IP, disconnect
and confirm that normal network access returns.

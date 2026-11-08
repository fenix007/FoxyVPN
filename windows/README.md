# FoxyVPN for Windows

Experimental native Windows Forms client for Windows 10/11 x64, with a build
option for Windows ARM64. Firefox Account sign-in uses Edge WebView2. The local
protocol backend and sing-box create a dual-stack TUN connection for TCP and DNS.

## Build

Install .NET 10 SDK, Go 1.26 or newer, Python 3 and Git. From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File windows/scripts/build.ps1
# Optional Windows ARM64 build:
powershell -ExecutionPolicy Bypass -File windows/scripts/build.ps1 -Architecture arm64
```

On macOS/Linux with the same SDKs installed, cross-compile using
`windows/scripts/build.sh` (or `windows/scripts/build.sh arm64`).
Set `FOXYVPN_GO_BIN` / `FOXYVPN_DOTNET_BIN` for custom toolchain locations.

Output: `windows/dist/FoxyVPN-win-x64.zip` (or `win-arm64.zip`). .NET is included
in the application, so the destination PC does not need the .NET runtime.
The target PC does need Microsoft Edge WebView2 Runtime, normally present on
Windows 10/11. Dependencies are pinned; see [THIRD_PARTY.md](THIRD_PARTY.md).
The protocol backend's redistribution terms are unresolved, so complete builds
are currently intended for local use and are not uploaded to public releases.

## Connect

1. Extract the complete ZIP into a trusted local folder. Keep `FoxyVPN.exe`,
   `foxyvpn-proxy.exe` and `sing-box.exe` together.
2. Run `FoxyVPN.exe` and accept Windows administrator authorization for TUN.
3. Click **Войти в Firefox…**, use your Mozilla password and complete session
   confirmation. Google/Apple login is not supported by this Sync login flow.
4. Choose a country and click **Подключить VPN**. Account entitlement, quota and
   country availability are controlled by Mozilla.
5. **Отключить VPN** or closing the app stops both backends. Windows Job Objects
   also stop them if the GUI exits unexpectedly.

Traffic statistics show received/sent bytes, current speed and saved lifetime
usage for this Windows installation. Counters start at connection and include
TUN packet headers; direct traffic is excluded. These are not Mozilla quota data.
Country and totals are saved in `%LOCALAPPDATA%\FoxyVPN`.
Credentials use Windows DPAPI for the current user. Temporary backend tokens
are stored in a directory restricted to the current user and SYSTEM, removed
on disconnect. A crash can leave such a private directory until the next launch, which cleans
up stale runtime and login directories.
WebView2 sign-in uses a separate temporary profile with password saving disabled.

## Scope and verification

- IPv4/IPv6 TCP and DNS through the TUN; other UDP is rejected. Browsers can
  fall back from QUIC to TCP. UDP-only applications are unsupported.
- Local networks and the Firefox backend process bypass the tunnel.
- DNS uses HTTPS through the proxy; sing-box `strict_route` is enabled for
  Windows DNS handling. A full live Windows DNS/IPv6 leak check is still required.
- No persistent kill switch. Other VPNs can change routes; test one at a time.
- Site exceptions from the macOS UI are not yet present in this initial port.
- The entire application runs elevated. Install only in a folder you trust;
  there is no background service or persistent system proxy change.

```powershell
dotnet run --project windows/FoxyVPN.Tests -c Release
Start-Process windows/dist/FoxyVPN-win-x64/FoxyVPN.exe -ArgumentList '--self-test' -Wait
```

The self-test checks configuration parsing, backend CLI and the Windows Job
Object. It does not connect a real account or create a TUN adapter. For an
end-to-end test on Windows, sign in, connect, inspect exit IP, IPv6 and DNS,
transfer data and confirm counters increase, then disconnect and verify normal
routing returns. Cross-compiling on macOS cannot validate the Windows driver.

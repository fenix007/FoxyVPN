# Windows third-party components

- Firefox VPN protocol backend: UjuiUjuMandan/firefox-vpn-client,
  revision `55ad91a2ccea1c93e69c82a08a7681e279884db5`, using the shared
  `macos/Backend/firefox-vpn-client-macos.patch`. The pinned source has no
  license notice. Builds are for local use; do not publish binaries containing
  this component until redistribution terms have been clarified with its author.
- sing-box 1.14.4: SagerNet/sing-box,
  revision `c005f35300ce76427dc285481ec5695f5b179cd2`, GPL-3.0-or-later.
  Includes the embedded Wintun component supplied by sing-tun; see its upstream
  notices. Full pinned sources remain in `windows/.build/sources` and modules
  in `windows/.build/go-mod-cache` after a build.
- .NET 10: Microsoft, MIT; includes components with notices in the .NET runtime.
- Microsoft.Web.WebView2 SDK 1.0.4314.35: Microsoft, proprietary SDK/runtime
  redistribution terms. The Edge WebView2 Runtime is installed separately.

Windows builds are unsigned and experimental. The GitHub workflow builds and
checks the complete package and saves the ZIP and its SHA-256 checksum as an
Actions artifact. The separate Desktop release workflow attaches tagged builds
to GitHub Releases. The protocol backend's redistribution terms above remain
unresolved. No credentials or private runtime files belong in a build archive.

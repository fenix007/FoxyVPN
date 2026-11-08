#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${FOXYVPN_CONFIGURATION:-release}"
case "$configuration" in release|debug) ;; *) echo "Invalid configuration" >&2; exit 1 ;; esac
"$project_dir/scripts/prepare-backends.sh"
cd "$project_dir"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app="$project_dir/dist/FoxyVPN.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin_dir/FoxyVPN" "$app/Contents/MacOS/FoxyVPN"
install -m 755 "$bin_dir/foxyvpn-tunnel" "$app/Contents/Resources/foxyvpn-tunnel"
install -m 755 "$project_dir/.build/backends/foxyvpn-proxy" "$app/Contents/Resources/foxyvpn-proxy"
install -m 755 "$project_dir/.build/backends/sing-box" "$app/Contents/Resources/sing-box"
cp "$project_dir/THIRD_PARTY.md" "$app/Contents/Resources/THIRD_PARTY.md"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FoxyVPN</string>
<key>CFBundleIdentifier</key><string>com.vauth.foxyvpn.macos</string>
<key>CFBundleName</key><string>FoxyVPN</string>
<key>CFBundleDisplayName</key><string>FoxyVPN</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
for executable in foxyvpn-tunnel foxyvpn-proxy sing-box; do
  codesign --force --sign - "$app/Contents/Resources/$executable"
done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/FoxyVPN" --self-test
printf 'Built: %s\n' "$app"
if [ "${1:-}" = "--install" ]; then
  destination="$HOME/Applications/FoxyVPN.app"
  mkdir -p "$HOME/Applications"
  if pgrep -f "$destination/Contents/MacOS/FoxyVPN" >/dev/null; then
    echo "Quit FoxyVPN before replacing the installed application." >&2
    exit 1
  fi
  if [ -e "$destination" ]; then
    echo "An installation already exists at $destination; move it aside before installing." >&2
    exit 1
  fi
  ditto "$app" "$destination"
  codesign --verify --deep --strict "$destination"
  printf 'Installed: %s\n' "$destination"
fi

#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
"$project_dir/scripts/build-app.sh"

app="${FOXYVPN_APP_OUTPUT:-$project_dir/dist/FoxyVPN.app}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "Invalid app version" >&2; exit 1; }
dmg="$project_dir/dist/FoxyVPN-$version-macos-arm64.dmg"
staging="$(mktemp -d "$project_dir/.build/dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

ditto "$app" "$staging/FoxyVPN.app"
ln -s /Applications "$staging/Applications"
cp "$project_dir/INSTALL.ru.txt" "$staging/INSTALL.txt"
cp "$project_dir/../LICENSE" "$staging/LICENSE"
codesign --verify --deep --strict "$staging/FoxyVPN.app"

hdiutil create -volname FoxyVPN -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
hdiutil verify "$dmg"
cd "$project_dir/dist"
shasum -a 256 "$(basename "$dmg")" > "$dmg.sha256"
printf 'Ready to share: %s\n' "$dmg"

#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_png="$project_dir/../assets/branding/foxy-superhero-desktop.png"
output_dir="$project_dir/.build/branding"
iconset="$output_dir/FoxyVPN.iconset"
[[ -f "$source_png" ]] || { echo "Missing prepared desktop artwork: $source_png (run scripts/prepare-branding.ps1 on Windows)" >&2; exit 1; }

dimensions="$(sips -g pixelWidth -g pixelHeight "$source_png")"
width="$(printf '%s\n' "$dimensions" | awk '/pixelWidth:/ { print $2 }')"
height="$(printf '%s\n' "$dimensions" | awk '/pixelHeight:/ { print $2 }')"
[[ "$width" =~ ^[0-9]+$ && "$height" == "$width" && "$width" -ge 512 ]] || {
  echo 'The source icon must be square and at least 512 by 512 pixels (1024 recommended).' >&2
  exit 1
}

mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$source_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$output_dir/FoxyVPN.icns"
printf 'Prepared: %s\n' "$output_dir/FoxyVPN.icns"

#!/usr/bin/env bash
set -euo pipefail
WINDOWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARCH="${1:-x64}"
case "$ARCH" in
  x64) GO_ARCH=amd64 ;;
  arm64) GO_ARCH=arm64 ;;
  *) echo 'Usage: build.sh [x64|arm64]' >&2; exit 1 ;;
esac
DOTNET_BIN="${FOXYVPN_DOTNET_BIN:-dotnet}"
OUTPUT="$WINDOWS_DIR/dist/FoxyVPN-win-$ARCH"
python3 "$WINDOWS_DIR/scripts/prepare-backends.py" --arch "$GO_ARCH"
"$DOTNET_BIN" run --project "$WINDOWS_DIR/FoxyVPN.Tests" -c Release
"$DOTNET_BIN" publish "$WINDOWS_DIR/FoxyVPN/FoxyVPN.csproj" -c Release -r "win-$ARCH" --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o "$OUTPUT"
cp "$WINDOWS_DIR/.build/backends/$GO_ARCH/foxyvpn-proxy.exe" "$WINDOWS_DIR/.build/backends/$GO_ARCH/sing-box.exe" "$OUTPUT/"
cp "$WINDOWS_DIR/README.md" "$WINDOWS_DIR/THIRD_PARTY.md" "$WINDOWS_DIR/../LICENSE" "$OUTPUT/"
python3 - "$OUTPUT" <<'PY'
import hashlib
from pathlib import Path
import sys
import zipfile
output = Path(sys.argv[1])
for item in output.iterdir():
    if item.suffix in ('.pdb', '.xml'):
        item.unlink()
archive = output.with_suffix('.zip')
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
    for item in sorted(output.rglob('*')):
        if item.is_file():
            z.write(item, item.relative_to(output))
h = hashlib.sha256()
with archive.open('rb') as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b''):
        h.update(chunk)
print(f'{h.hexdigest()}  {archive}')
PY

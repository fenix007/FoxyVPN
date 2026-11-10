#!/usr/bin/env bash
set -euo pipefail

: "${GH_REPO:?Missing GitHub repository}"
: "${GH_TOKEN:?Missing GitHub token}"
: "${RELEASE_TAG:?Missing release tag}"
: "${SOURCE_SHA:?Missing source commit}"
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]

# Refuse to publish a build if the tag moved while its jobs were running.
git fetch --no-tags origin "refs/tags/$RELEASE_TAG"
[[ "$(git rev-parse 'FETCH_HEAD^{commit}')" == "$SOURCE_SHA" ]] || {
  echo 'The release tag moved after the build started' >&2
  exit 1
}

(
  cd downloads
  sha256sum --check FoxyVPN-*-macos-arm64.dmg.sha256
  sha256sum --check FoxyVPN-win-x64.zip.sha256
)
mkdir -p release-assets
cp downloads/FoxyVPN-*-macos-arm64.dmg release-assets/FoxyVPN-macos-arm64.dmg
cp downloads/FoxyVPN-win-x64.zip release-assets/FoxyVPN-windows-x64.zip
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
cat > "$work_dir/notes.md" <<NOTES
<!-- foxyvpn-desktop-release:$SOURCE_SHA -->
Готовые сборки FoxyVPN для macOS и Windows.

- **Mac с Apple Silicon, macOS 14+:** скачайте FoxyVPN-macos-arm64.dmg, откройте и перетащите приложение в Applications («Программы»).
- **Windows 10/11 x64:** скачайте FoxyVPN-windows-x64.zip, распакуйте целиком и запустите FoxyVPN.exe. Нужен Microsoft Edge WebView2 Runtime.
- SHA256SUMS-desktop.txt содержит контрольные суммы обоих файлов.

Сборка Mac имеет локальную подпись без нотариализации Apple. Если первый запуск заблокирован, откройте «Системные настройки → Конфиденциальность и безопасность → Всё равно открыть». Windows-сборка не подписана.

Это экспериментальный неофициальный клиент. Известные ограничения описаны в [macOS README](https://github.com/$GH_REPO/blob/$SOURCE_SHA/macos/README.md) и [Windows README](https://github.com/$GH_REPO/blob/$SOURCE_SHA/windows/README.md).

Исходники: тег $RELEASE_TAG, коммит $SOURCE_SHA.
NOTES

read_release() {
  gh release view "$RELEASE_TAG" --json body,isDraft,assets,url > "$work_dir/release.json"
}

if ! read_release; then
  # A concurrent Android job may create the release between view and create.
  if ! gh release create "$RELEASE_TAG" --verify-tag --draft \
    --title "FoxyVPN $RELEASE_TAG" --notes-file "$work_dir/notes.md"; then
    read_release
  fi
  read_release
fi

if jq -e '.isDraft' "$work_dir/release.json" >/dev/null; then
  if ! jq -e --arg marker "<!-- foxyvpn-desktop-release:$SOURCE_SHA -->" \
    '(.body // "") | contains($marker)' "$work_dir/release.json" >/dev/null; then
    echo 'An unrelated draft exists for this tag; leaving it unchanged' >&2
    exit 1
  fi
fi

# Preserve existing downloads, including immutable releases. On a partial retry,
# use the existing bytes for checksums: a newly built DMG may differ byte-for-byte.
has_asset() {
  jq -e --arg name "$1" \
    '.assets[] | select(.name == $name and .size > 0)' "$work_dir/release.json" >/dev/null
}
for name in FoxyVPN-macos-arm64.dmg FoxyVPN-windows-x64.zip; do
  asset="release-assets/$name"
  if has_asset "$name"; then
    gh release download "$RELEASE_TAG" --pattern "$name" --dir release-assets --clobber
  else
    gh release upload "$RELEASE_TAG" "$asset"
  fi
done
(
  cd release-assets
  sha256sum FoxyVPN-macos-arm64.dmg FoxyVPN-windows-x64.zip > SHA256SUMS-desktop.txt
)
if has_asset SHA256SUMS-desktop.txt; then
  gh release download "$RELEASE_TAG" --pattern SHA256SUMS-desktop.txt --dir "$work_dir"
  cmp release-assets/SHA256SUMS-desktop.txt "$work_dir/SHA256SUMS-desktop.txt"
else
  gh release upload "$RELEASE_TAG" release-assets/SHA256SUMS-desktop.txt
fi
if jq -e '.isDraft' "$work_dir/release.json" >/dev/null; then
  gh release edit "$RELEASE_TAG" --draft=false
fi
gh release view "$RELEASE_TAG" --json url,assets

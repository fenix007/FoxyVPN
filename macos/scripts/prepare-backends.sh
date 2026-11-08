#!/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly BUILD_DIR="$MACOS_DIR/.build"
readonly SOURCES_DIR="$BUILD_DIR/sources"
readonly BACKENDS_DIR="$BUILD_DIR/backends"
readonly DOWNLOADS_DIR="$BUILD_DIR/downloads"
readonly TOOLCHAINS_DIR="$BUILD_DIR/toolchains"
readonly GO_CACHE_DIR="$BUILD_DIR/go-cache"
readonly GO_MODULE_CACHE_DIR="$BUILD_DIR/go-mod-cache"

readonly GO_VERSION="1.27.3"
readonly GO_ARCHIVE="go${GO_VERSION}.darwin-arm64.tar.gz"
readonly GO_SHA256="dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2"
readonly GO_URL="https://go.dev/dl/$GO_ARCHIVE"

readonly FIREFOX_REPOSITORY="https://github.com/UjuiUjuMandan/firefox-vpn-client.git"
readonly FIREFOX_COMMIT="55ad91a2ccea1c93e69c82a08a7681e279884db5"
readonly FIREFOX_SOURCE="$SOURCES_DIR/firefox-vpn-client"
readonly FIREFOX_PATCH="$MACOS_DIR/Backend/firefox-vpn-client-macos.patch"

readonly SING_BOX_REPOSITORY="https://github.com/SagerNet/sing-box.git"
readonly SING_BOX_VERSION="1.14.4"
readonly SING_BOX_COMMIT="c005f35300ce76427dc285481ec5695f5b179cd2"
readonly SING_BOX_SOURCE="$SOURCES_DIR/sing-box"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(sha256_file "$file")"
  [[ "$actual" == "$expected" ]] || die "checksum mismatch for $file (expected $expected, got $actual)"
}

prepare_go() {
  if [[ -n "${FOXYVPN_GO_BIN:-}" ]]; then
    [[ -x "$FOXYVPN_GO_BIN" ]] || die "FOXYVPN_GO_BIN is not executable: $FOXYVPN_GO_BIN"
    GO_BIN="$FOXYVPN_GO_BIN"
  else
    local archive="$DOWNLOADS_DIR/$GO_ARCHIVE"
    local toolchain="$TOOLCHAINS_DIR/go${GO_VERSION}"
    GO_BIN="$toolchain/go/bin/go"

    if [[ ! -x "$GO_BIN" ]]; then
      if [[ ! -f "$archive" ]]; then
        printf 'Downloading Go %s...\n' "$GO_VERSION"
        curl --fail --location --proto '=https' --proto-redir '=https' --output "$archive" "$GO_URL"
      fi
      verify_sha256 "$archive" "$GO_SHA256"

      [[ ! -e "$toolchain" ]] || die "incomplete Go toolchain exists at $toolchain; remove that cache directory and retry"
      local staging
      staging="$(mktemp -d "$TOOLCHAINS_DIR/.go${GO_VERSION}.XXXXXX")"
      tar -xzf "$archive" -C "$staging"
      [[ -x "$staging/go/bin/go" ]] || die "downloaded Go archive has an unexpected layout"
      mv "$staging" "$toolchain"
    fi
  fi

  local go_host_os go_host_arch go_version go_minor
  go_host_os="$($GO_BIN env GOHOSTOS)"
  go_host_arch="$($GO_BIN env GOHOSTARCH)"
  go_version="$($GO_BIN env GOVERSION)"
  go_minor="$(printf '%s' "$go_version" | sed -E 's/^go1\.([0-9]+).*/\1/')"
  [[ "$go_host_os" == "darwin" && "$go_host_arch" == "arm64" ]] || die "Go must run natively on darwin/arm64 (got $go_host_os/$go_host_arch)"
  [[ "$go_minor" =~ ^[0-9]+$ && "$go_minor" -ge 26 ]] || die "Go 1.26 or newer is required (got $go_version)"
  printf 'Using %s\n' "$($GO_BIN version)"
}

checkout_exact_commit() {
  local repository="$1"
  local commit="$2"
  local destination="$3"

  if [[ ! -d "$destination/.git" ]]; then
    [[ ! -e "$destination" ]] || die "source path exists but is not a Git checkout: $destination"
    mkdir -p "$destination"
    git -C "$destination" init --quiet
    git -C "$destination" remote add origin "$repository"
    git -C "$destination" fetch --quiet --depth 1 origin "$commit"
    git -C "$destination" checkout --quiet --detach FETCH_HEAD
  fi

  local actual
  actual="$(git -C "$destination" rev-parse HEAD)"
  [[ "$actual" == "$commit" ]] || die "unexpected source revision in $destination (expected $commit, got $actual)"
}

prepare_firefox_source() {
  checkout_exact_commit "$FIREFOX_REPOSITORY" "$FIREFOX_COMMIT" "$FIREFOX_SOURCE"

  if git -C "$FIREFOX_SOURCE" apply --check "$FIREFOX_PATCH" 2>/dev/null; then
    git -C "$FIREFOX_SOURCE" apply "$FIREFOX_PATCH"
  elif ! git -C "$FIREFOX_SOURCE" apply --reverse --check "$FIREFOX_PATCH" 2>/dev/null; then
    die "Firefox client checkout contains changes other than the expected macOS patch: $FIREFOX_SOURCE"
  fi

  local changed
  changed="$(git -C "$FIREFOX_SOURCE" diff --name-only | LC_ALL=C sort)"
  local expected=$'cmd/proxy-demo/main.go\ncmd/proxy-demo/main_test.go\nfirefox_identity_test.go\nfxa.go\ntokens.go\ntokens_test.go'
  [[ "$changed" == "$expected" ]] || die "unexpected modified files in Firefox client checkout: ${changed:-none}"
}

prepare_sing_box_source() {
  checkout_exact_commit "$SING_BOX_REPOSITORY" "$SING_BOX_COMMIT" "$SING_BOX_SOURCE"
  git -C "$SING_BOX_SOURCE" diff --quiet || die "sing-box checkout is modified: $SING_BOX_SOURCE"
}

run_go() {
  env GOCACHE="$GO_CACHE_DIR" GOMODCACHE="$GO_MODULE_CACHE_DIR" CGO_ENABLED=1 "$GO_BIN" "$@"
}

build_backends() {
  printf 'Testing Firefox VPN protocol backend...\n'
  (cd "$FIREFOX_SOURCE" && run_go test ./...)
  printf 'Building Firefox VPN protocol backend...\n'
  (cd "$FIREFOX_SOURCE" && run_go build -trimpath -buildvcs=false -o "$BACKENDS_DIR/foxyvpn-proxy" ./cmd/proxy-demo)

  printf 'Building sing-box %s...\n' "$SING_BOX_VERSION"
  (cd "$SING_BOX_SOURCE" && run_go build -trimpath -buildvcs=false -o "$BACKENDS_DIR/sing-box" ./cmd/sing-box)

  [[ "$(file "$BACKENDS_DIR/foxyvpn-proxy")" == *"arm64"* ]] || die "foxyvpn-proxy is not an arm64 binary"
  [[ "$(file "$BACKENDS_DIR/sing-box")" == *"arm64"* ]] || die "sing-box is not an arm64 binary"
  "$BACKENDS_DIR/sing-box" version

  printf '\nBackend artifacts:\n'
  shasum -a 256 "$BACKENDS_DIR/foxyvpn-proxy" "$BACKENDS_DIR/sing-box"
}

main() {
  [[ "$(uname -s)" == "Darwin" ]] || die "this builder supports macOS only"
  [[ "$(uname -m)" == "arm64" ]] || die "this builder supports Apple Silicon only"
  command -v curl >/dev/null || die "curl is required"
  command -v git >/dev/null || die "git is required"
  command -v shasum >/dev/null || die "shasum is required"
  command -v xcrun >/dev/null || die "Xcode Command Line Tools are required"

  mkdir -p "$SOURCES_DIR" "$BACKENDS_DIR" "$DOWNLOADS_DIR" "$TOOLCHAINS_DIR" "$GO_CACHE_DIR" "$GO_MODULE_CACHE_DIR"
  prepare_go
  prepare_firefox_source
  prepare_sing_box_source
  build_backends
}

main "$@"

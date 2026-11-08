#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
swift_bin="$(xcrun --find swiftc)"
toolchain_dir="$(cd "$(dirname "$swift_bin")/.." && pwd)"
plugin_dir="$toolchain_dir/lib/swift/host/plugins/testing"
arguments=(test --package-path "$project_dir" --disable-xctest)
# Some Command Line Tools releases omit this path during module emission.
if [[ -d "$plugin_dir" && -x "$toolchain_dir/bin/swift-plugin-server" ]]; then
  arguments+=(-Xswiftc -external-plugin-path -Xswiftc "$plugin_dir#$toolchain_dir/bin/swift-plugin-server")
fi
swift "${arguments[@]}" "$@"

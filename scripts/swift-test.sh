#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="$repo_root/.swift-cache"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

developer_dir="$(xcode-select -p)"
framework_dir="$developer_dir/Library/Developer/Frameworks"
interop_dir="$developer_dir/Library/Developer/usr/lib"

swift_test_args=(test --disable-sandbox)
if [[ -d "$framework_dir/Testing.framework" && -f "$interop_dir/lib_TestingInterop.dylib" ]]; then
  swift_test_args+=(
    -Xswiftc -F -Xswiftc "$framework_dir"
    -Xlinker -F -Xlinker "$framework_dir"
    -Xlinker -rpath -Xlinker "$framework_dir"
    -Xlinker -rpath -Xlinker "$interop_dir"
  )
fi

exec swift "${swift_test_args[@]}" "$@"

#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd)
APP_BUNDLE="$REPOSITORY_ROOT/dist/Kotobane.app"
ENTITLEMENTS=$(mktemp "${TMPDIR:-/tmp}/kotobane-entitlements.XXXXXX")
CACHE_ROOT="$REPOSITORY_ROOT/.swift-cache"

export CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_ROOT/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

cleanup() {
    rm -f -- "$ENTITLEMENTS"
}
trap cleanup EXIT HUP INT TERM

cd "$REPOSITORY_ROOT"

scripts/swift-test.sh
python3 -m unittest discover -s helper/tests -v
swift build --disable-sandbox -c release --product Kotobane
swift build --disable-sandbox -c release --product kotobane-launch-shim
scripts/package-app.sh
plutil -lint Resources/Info.plist
codesign --verify --deep --strict "$APP_BUNDLE"

test -x "$APP_BUNDLE/Contents/Helpers/kotobane-launch-shim"
codesign --display --entitlements :- "$APP_BUNDLE" >"$ENTITLEMENTS" 2>/dev/null
python3 - "$ENTITLEMENTS" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as entitlement_file:
    entitlements = plistlib.load(entitlement_file)

network_keys = (
    "com.apple.security.network.client",
    "com.apple.security.network.server",
)
present = [key for key in network_keys if entitlements.get(key)]
if present:
    raise SystemExit(
        "Kotobane.app unexpectedly grants network entitlements: "
        + ", ".join(present)
    )
PY

echo "Kotobane verification passed."

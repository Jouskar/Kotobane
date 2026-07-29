#!/bin/sh
set -eu

if [ "$(uname -m)" != "arm64" ]; then
    echo "Kotobane packaging requires an Apple-silicon (arm64) Mac." >&2
    exit 1
fi

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd)
APP_BUNDLE="$REPOSITORY_ROOT/dist/Kotobane.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIRECTORY="$CONTENTS/MacOS"
HELPERS_DIRECTORY="$CONTENTS/Helpers"
RESOURCES_DIRECTORY="$CONTENTS/Resources"
CACHE_ROOT="$REPOSITORY_ROOT/.swift-cache"

export CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_ROOT/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

cd "$REPOSITORY_ROOT"

swift build --disable-sandbox -c release --product Kotobane
swift build --disable-sandbox -c release --product kotobane-launch-shim
RELEASE_BIN_DIRECTORY=$(swift build --disable-sandbox -c release --show-bin-path)

rm -rf -- "$APP_BUNDLE"
mkdir -p "$MACOS_DIRECTORY" "$HELPERS_DIRECTORY" "$RESOURCES_DIRECTORY"

install -m 755 "$RELEASE_BIN_DIRECTORY/Kotobane" "$MACOS_DIRECTORY/Kotobane"
install -m 755 \
    "$RELEASE_BIN_DIRECTORY/kotobane-launch-shim" \
    "$HELPERS_DIRECTORY/kotobane-launch-shim"
install -m 755 helper/kotobane_helper.py "$HELPERS_DIRECTORY/kotobane_helper.py"
install -m 644 helper/model_install.py "$HELPERS_DIRECTORY/model_install.py"
install -m 644 helper/requirements.lock "$HELPERS_DIRECTORY/requirements.lock"
install -m 644 helper/runtime-manifest.json "$HELPERS_DIRECTORY/runtime-manifest.json"
install -m 755 scripts/bootstrap-helper.sh "$HELPERS_DIRECTORY/bootstrap-helper.sh"
install -m 644 Resources/Info.plist "$CONTENTS/Info.plist"
install -m 644 Resources/AppIcon.icns "$RESOURCES_DIRECTORY/AppIcon.icns"
install -m 644 \
    Resources/Kotobane.entitlements \
    "$RESOURCES_DIRECTORY/Kotobane.entitlements"

codesign \
    --force \
    --deep \
    --sign - \
    --entitlements Resources/Kotobane.entitlements \
    "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "Packaged $APP_BUNDLE"

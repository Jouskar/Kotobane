#!/bin/sh
set -eu
umask 077

if [ "$(uname -m)" != "arm64" ]; then
    echo "Kotobane's local transcription runtime requires Apple silicon (arm64)." >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ASSET_DIRECTORY="$SCRIPT_DIR"
if [ ! -f "$ASSET_DIRECTORY/runtime-manifest.json" ] ||
    [ ! -f "$ASSET_DIRECTORY/requirements.lock" ]; then
    REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
    ASSET_DIRECTORY="$REPOSITORY_ROOT/helper"
fi
MANIFEST="$ASSET_DIRECTORY/runtime-manifest.json"
REQUIREMENTS="$ASSET_DIRECTORY/requirements.lock"
if [ ! -f "$MANIFEST" ] || [ ! -f "$REQUIREMENTS" ]; then
    echo "Kotobane's pinned runtime manifest and requirements lock were not found." >&2
    exit 1
fi
APP_SUPPORT_ROOT=${1:-"$HOME/Library/Application Support/Kotobane"}
RUNTIME_DESTINATION="$APP_SUPPORT_ROOT/runtime"
RUNTIME_READY="$RUNTIME_DESTINATION/ready.json"

if [ -e "$RUNTIME_DESTINATION" ]; then
    if [ -f "$RUNTIME_READY" ] && [ ! -L "$RUNTIME_READY" ]; then
        echo "Runtime destination is already ready: $RUNTIME_DESTINATION" >&2
        exit 1
    fi
    rm -rf -- "$RUNTIME_DESTINATION"
fi

ARCHIVE_URL=$(/usr/bin/plutil -extract url raw -o - "$MANIFEST")
ARCHIVE_SHA256=$(/usr/bin/plutil -extract sha256 raw -o - "$MANIFEST")
ARCHIVE_SIZE=$(/usr/bin/plutil -extract archiveSize raw -o - "$MANIFEST")

mkdir -p "$APP_SUPPORT_ROOT"
chmod 700 "$APP_SUPPORT_ROOT"
STAGING=$(mktemp -d "$APP_SUPPORT_ROOT/.runtime-staging.XXXXXXXX")
ARCHIVE="$STAGING/python-runtime.tar.gz"
INSTALLING=0

cleanup() {
    rm -rf -- "$STAGING"
    if [ "$INSTALLING" = "1" ] && [ ! -f "$RUNTIME_READY" ]; then
        rm -rf -- "$RUNTIME_DESTINATION"
    fi
}
trap cleanup EXIT HUP INT TERM

/usr/bin/curl --fail --location --proto '=https' --tlsv1.2 \
    --output "$ARCHIVE" "$ARCHIVE_URL"

ACTUAL_SIZE=$(wc -c < "$ARCHIVE" | tr -d '[:space:]')
if [ "$ACTUAL_SIZE" != "$ARCHIVE_SIZE" ]; then
    echo "Python runtime archive size mismatch." >&2
    exit 1
fi

ACTUAL_SHA256=$(/usr/bin/shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$ARCHIVE_SHA256" ]; then
    echo "Python runtime archive checksum mismatch." >&2
    exit 1
fi

/usr/bin/tar -xzf "$ARCHIVE" -C "$STAGING"
rm -f -- "$ARCHIVE"

if [ ! -x "$STAGING/python/bin/python3" ]; then
    echo "Pinned Python archive did not contain python/bin/python3." >&2
    exit 1
fi

INSTALLING=1
mkdir -p "$RUNTIME_DESTINATION"
mv "$STAGING/python" "$RUNTIME_DESTINATION/python"
"$RUNTIME_DESTINATION/python/bin/python3" -m venv "$RUNTIME_DESTINATION/venv"
"$RUNTIME_DESTINATION/venv/bin/python" -m pip install \
    --no-cache-dir \
    --only-binary=:all: \
    --require-hashes \
    --requirement "$REQUIREMENTS"

"$RUNTIME_DESTINATION/venv/bin/python" -c \
    'import pathlib,sys; expected=pathlib.Path(sys.argv[1]).resolve(); actual=pathlib.Path(sys.prefix).resolve(); raise SystemExit(0 if actual == expected else 1)' \
    "$RUNTIME_DESTINATION/venv"

READY_TEMP="$RUNTIME_DESTINATION/.ready.$$"
printf '{"runtimeSHA256":"%s"}\n' "$ARCHIVE_SHA256" > "$READY_TEMP"
mv "$READY_TEMP" "$RUNTIME_READY"
INSTALLING=0
rm -rf -- "$STAGING"
trap - EXIT HUP INT TERM
echo "Kotobane helper runtime installed at $RUNTIME_DESTINATION"

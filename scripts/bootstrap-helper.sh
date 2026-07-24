#!/bin/sh
set -eu

if [ "$(uname -m)" != "arm64" ]; then
    echo "Kotobane's local transcription runtime requires Apple silicon (arm64)." >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPOSITORY_ROOT/helper/runtime-manifest.json"
REQUIREMENTS="$REPOSITORY_ROOT/helper/requirements.lock"
APP_SUPPORT_ROOT=${1:-"$HOME/Library/Application Support/Kotobane"}
RUNTIME_DESTINATION="$APP_SUPPORT_ROOT/runtime"

if [ -e "$RUNTIME_DESTINATION" ]; then
    echo "Runtime destination already exists: $RUNTIME_DESTINATION" >&2
    exit 1
fi

ARCHIVE_URL=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["url"])' \
    "$MANIFEST")
ARCHIVE_SHA256=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["sha256"])' \
    "$MANIFEST")
ARCHIVE_SIZE=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["archiveSize"])' \
    "$MANIFEST")

mkdir -p "$APP_SUPPORT_ROOT"
chmod 700 "$APP_SUPPORT_ROOT"
STAGING=$(mktemp -d "$APP_SUPPORT_ROOT/.runtime-staging.XXXXXXXX")
ARCHIVE="$STAGING/python-runtime.tar.gz"

cleanup() {
    rm -rf -- "$STAGING"
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

"$STAGING/python/bin/python3" -m venv "$STAGING/venv"
"$STAGING/venv/bin/python" -m pip install \
    --no-cache-dir \
    --only-binary=:all: \
    --require-hashes \
    --requirement "$REQUIREMENTS"

mv "$STAGING" "$RUNTIME_DESTINATION"
trap - EXIT HUP INT TERM
echo "Kotobane helper runtime installed at $RUNTIME_DESTINATION"

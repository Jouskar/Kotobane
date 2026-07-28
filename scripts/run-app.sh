#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd)
APP_BUNDLE="$REPOSITORY_ROOT/dist/Kotobane.app"

"$SCRIPT_DIRECTORY/package-app.sh"
open "$APP_BUNDLE"

#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SOURCE="build/MacStayAwake.app"
TARGET="/Applications/MacStayAwake.app"

if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: $SOURCE not found. Run scripts/build-app.sh first. Preview builds cannot be installed by this script." >&2
    exit 1
fi
if [[ -e "$TARGET" || -L "$TARGET" ]]; then
    echo "ERROR: Quit MacStayAwake and move $TARGET to Trash before replacing it." >&2
    exit 1
fi

REQUIREMENTS="$(swift -e "$(cat Sources/LidAwakeShared/HelperConstants.swift)"$'\n''print([HelperConstants.appRequirement, HelperConstants.helperRequirement].joined(separator: "\t"))')"
IFS=$'\t' read -r APP_REQ HELPER_REQ <<< "$REQUIREMENTS"
codesign --verify --strict -R="$APP_REQ" "$SOURCE"
codesign --verify --strict -R="$HELPER_REQ" "$SOURCE/Contents/MacOS/LidAwakeHelper"

ditto "$SOURCE" "$TARGET"
echo "Installed $TARGET. Helper registration still requires approval in System Settings."

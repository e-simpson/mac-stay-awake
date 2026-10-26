#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: scripts/notarize-app.sh /path/to/MacStayAwake.app TEAM_ID KEYCHAIN_PROFILE" >&2
    exit 64
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
TEAM="$2"
PROFILE="$3"
if [[ ! "$TEAM" =~ ^[A-Z0-9]{10}$ || -z "$PROFILE" ]]; then
    echo "ERROR: Supply a ten-character Team ID and a Keychain profile name." >&2
    exit 64
fi
if [[ ! -d "$APP" || "$(basename "$APP")" != MacStayAwake.app ]]; then
    echo "ERROR: Supply an existing MacStayAwake.app." >&2
    exit 1
fi
INFO="$APP/Contents/Info.plist"
if /usr/libexec/PlistBuddy -c "Print :MacStayAwakePreview" "$INFO" >/dev/null 2>&1; then
    echo "ERROR: Preview apps cannot be notarized for release." >&2
    exit 1
fi

# Derive identifiers and peer requirements from the same source as the build.
CONFIG="$(swift -e "$(cat "$ROOT/Sources/LidAwakeShared/HelperConstants.swift")"$'\n''print([HelperConstants.appBundleIdentifier, HelperConstants.teamIdentifier, HelperConstants.appRequirement, HelperConstants.helperRequirement].joined(separator: "\t"))')"
IFS=$'\t' read -r APP_ID CONFIG_TEAM APP_REQ HELPER_REQ <<< "$CONFIG"
APP_REQ="${APP_REQ//$CONFIG_TEAM/$TEAM}"
HELPER_REQ="${HELPER_REQ//$CONFIG_TEAM/$TEAM}"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" != "$APP_ID" ]]; then
    echo "ERROR: Bundle identifier does not match this source tree." >&2
    exit 1
fi
codesign --verify --strict -R="$APP_REQ" "$APP"
codesign --verify --strict -R="$HELPER_REQ" "$APP/Contents/MacOS/LidAwakeHelper"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
ARCH="$(lipo -archs "$APP/Contents/MacOS/LidAwake")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ( "$ARCH" != arm64 && "$ARCH" != x86_64 ) ]]; then
    echo "ERROR: Expected a numeric three-part version and a single supported architecture." >&2
    exit 1
fi
if [[ "$(lipo -archs "$APP/Contents/MacOS/LidAwakeHelper")" != "$ARCH" ]]; then
    echo "ERROR: App and helper architectures differ." >&2
    exit 1
fi

OUT="$ROOT/build/releases/$VERSION-$ARCH"
mkdir -p "$(dirname "$OUT")"
mkdir "$OUT" # Refuse replacement, including an earlier interrupted submission.
STAGED="$OUT/MacStayAwake.app"
ditto "$APP" "$STAGED"
ditto -c -k --sequesterRsrc --keepParent "$STAGED" "$OUT/submission.zip"
xcrun notarytool submit "$OUT/submission.zip" --keychain-profile "$PROFILE" \
    --no-wait --output-format plist > "$OUT/submission.plist"
ID="$(/usr/libexec/PlistBuddy -c 'Print :id' "$OUT/submission.plist")"
echo "Submission $ID; receipts retained in $OUT"
if ! xcrun notarytool wait "$ID" --keychain-profile "$PROFILE" \
    --timeout 20m --output-format plist > "$OUT/status.plist"; then
    echo "ERROR: Waiting failed. Inspect the saved submission ID and resume that submission; do not resubmit automatically." >&2
    exit 1
fi
xcrun notarytool log "$ID" --keychain-profile "$PROFILE" "$OUT/notarization-log.json"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$OUT/status.plist")" != Accepted ]]; then
    echo "ERROR: Apple did not accept the submission. Inspect notarization-log.json." >&2
    exit 1
fi
xcrun stapler staple "$STAGED"
xcrun stapler validate "$STAGED"
codesign --verify --strict -R="$APP_REQ" "$STAGED"
codesign --verify --strict -R="$HELPER_REQ" "$STAGED/Contents/MacOS/LidAwakeHelper"
spctl --assess --type execute --verbose=2 "$STAGED"

FILE="MacStayAwake-$VERSION-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGED" "$OUT/$FILE"
mkdir "$OUT/extracted"
ditto -x -k "$OUT/$FILE" "$OUT/extracted"
xcrun stapler validate "$OUT/extracted/MacStayAwake.app"
codesign --verify --strict -R="$APP_REQ" "$OUT/extracted/MacStayAwake.app"
codesign --verify --strict -R="$HELPER_REQ" "$OUT/extracted/MacStayAwake.app/Contents/MacOS/LidAwakeHelper"
(cd "$OUT" && shasum -a 256 "$FILE" > SHA256SUMS)
echo "Prepared $OUT/$FILE and SHA256SUMS. Review the notarization log before publishing."

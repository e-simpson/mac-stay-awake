#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="LidAwake"
HELPER_NAME="LidAwakeHelper"
BUNDLE_NAME="MacStayAwake"
PREVIEW_BUILD="${PREVIEW_BUILD:-0}"
case "$PREVIEW_BUILD" in
    0|1) ;;
    *) echo "ERROR: PREVIEW_BUILD must be 0 or 1." >&2; exit 1 ;;
esac

# Evaluate the runtime configuration instead of maintaining a second trust policy.
SIGNING_CONFIG="$(swift -e "$(cat Sources/LidAwakeShared/HelperConstants.swift)"$'\n''print([HelperConstants.appBundleIdentifier, HelperConstants.helperIdentifier, HelperConstants.teamIdentifier, HelperConstants.appRequirement, HelperConstants.helperRequirement].joined(separator: "\t"))')"
IFS=$'\t' read -r APP_ID HELPER_ID TEAM_ID APP_REQ HELPER_REQ <<< "$SIGNING_CONFIG"

if [[ "$PREVIEW_BUILD" == 0 ]]; then
    if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "ERROR: Set your own Apple Developer Team ID in Sources/LidAwakeShared/HelperConstants.swift. See SIGNING.md." >&2
        exit 1
    fi
    IDENTITIES="$(security find-identity -v -p codesigning)"
    IDENTITY="$(awk -v requested="${SIGN_IDENTITY:-}" -v team="($TEAM_ID)" '
        index($0, "Developer ID Application:") && index($0, team) &&
        (requested == "" || $2 == requested || index($0, "\"" requested "\"")) { print $2; exit }
    ' <<< "$IDENTITIES")"
    if [[ -z "$IDENTITY" ]]; then
        echo "ERROR: No matching Developer ID Application identity for your Team $TEAM_ID. See SIGNING.md; PREVIEW_BUILD=1 permits UI-only inspection." >&2
        exit 1
    fi
fi

# Apple silicon and Intel are built and shipped as separate apps, never as one
# universal binary. Each architecture gets its own SwiftPM scratch directory,
# because the build system puts the products of every architecture in the
# same folder.
ARCH="${ARCH:-arm64}"
case "$ARCH" in
    arm64)
        APP="$ROOT/build/$BUNDLE_NAME.app"
        SCRATCH=".build"
        ;;
    x86_64)
        APP="$ROOT/build/x86_64/$BUNDLE_NAME.app"
        SCRATCH=".build/x86_64"
        ;;
    *)
        echo "ERROR: unknown ARCH '$ARCH'. Use arm64 or x86_64." >&2
        exit 1
        ;;
esac
BUILD_FLAGS=()
if [[ "$PREVIEW_BUILD" == 1 ]]; then
    APP="${APP%/*}/preview/$BUNDLE_NAME.app"
    SCRATCH="$SCRATCH/preview"
    BUILD_FLAGS=(-Xswiftc -DPERSONAL_PREVIEW)
fi
HELPER="$APP/Contents/MacOS/$HELPER_NAME"

# The Swift driver links via clang with --sysroot, from which clang does not
# read the SDK version, so LC_BUILD_VERSION would record the deployment target
# as the SDK. Passing -isysroot to the linking clang records the real SDK.
# The linker's -S drops the debug map, which records the absolute paths of the
# source directories and object files.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
swift build -c release --arch "$ARCH" --scratch-path "$SCRATCH" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} \
    -Xswiftc -Xclang-linker -Xswiftc -isysroot \
    -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH" \
    -Xlinker -S
BIN_DIR="$(swift build -c release --arch "$ARCH" --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/$HELPER_NAME" "$HELPER"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "Resources/$HELPER_ID.plist" "$APP/Contents/Library/LaunchDaemons/$HELPER_ID.plist"

# actool can exit with 0 after an error, so the outputs are checked below.
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
mkdir -p "$APP/Contents/Resources"
xcrun actool "$ROOT/Resources/AppIcon.icon" \
    --compile "$APP/Contents/Resources" \
    --app-icon AppIcon \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 13.0 \
    --output-partial-info-plist "$ICON_TMP/partial.plist" \
    --output-format human-readable-text --errors --warnings --notices
for ICON_FILE in Assets.car AppIcon.icns; do
    if [[ ! -f "$APP/Contents/Resources/$ICON_FILE" ]]; then
        echo "ERROR: actool did not produce $ICON_FILE from Resources/AppIcon.icon." >&2
        exit 1
    fi
done

for LPROJ in Resources/*.lproj; do
    plutil -lint -s "$LPROJ"/*.strings
    cp -R "$LPROJ" "$APP/Contents/Resources/"
done

mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE LICENSE-BRIGHTNESS-REFERENCE NOTICE "$APP/Contents/Resources/Licenses/"

if [[ "$PREVIEW_BUILD" == 1 ]]; then
    /usr/libexec/PlistBuddy -c "Add :MacStayAwakePreview bool true" "$APP/Contents/Info.plist"
    codesign --force --sign - --identifier "$HELPER_ID" "$HELPER"
    codesign --force --sign - "$APP"
    echo "PREVIEW ONLY: ad-hoc signed; privileged helper registration is disabled." >&2
else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier "$HELPER_ID" "$HELPER"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"

    # These are the exact strict Developer ID requirements used on both XPC peers.
    codesign --verify --strict -R="$HELPER_REQ" "$HELPER"
    codesign --verify --strict -R="$APP_REQ" "$APP"
    echo "Signatures satisfy the personal app and helper requirements for Team $TEAM_ID"
fi

codesign --verify --strict "$HELPER"
codesign --verify --strict "$APP"

for BINARY in "$APP/Contents/MacOS/$APP_NAME" "$HELPER"; do
    BINARY_ARCHS="$(lipo -archs "$BINARY")"
    if [[ "$BINARY_ARCHS" != "$ARCH" ]]; then
        echo "ERROR: $BINARY is built for '$BINARY_ARCHS', expected exactly '$ARCH'." >&2
        exit 1
    fi
done
echo "Architecture: $ARCH"

echo "Built $APP"

#!/bin/bash
# Build Earshot AutoGain.app with its embedded AUv3 extension.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Earshot AutoGain"
BIN_NAME="EarshotAutoGain"
EXT_NAME="AutoGainAU"
BUNDLE="$APP_NAME.app"
APPEX="$BUNDLE/Contents/PlugIns/$EXT_NAME.appex"
TARGET="arm64-apple-macosx13.0"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" \
         "$BUNDLE/Contents/Resources" \
         "$APPEX/Contents/MacOS"

cp Info.plist           "$BUNDLE/Contents/Info.plist"
cp Extension-Info.plist "$APPEX/Contents/Info.plist"

# ---------------------------------------------------------------------------
# 1. The extension. This is the part the host actually loads.
#
#    Two flags matter and are easy to miss when building outside Xcode:
#      -application-extension  restricts the API surface to what an appex may
#                              legally call, and marks the binary accordingly.
#      -e _NSExtensionMain     app extensions have no main(); the entry point
#                              lives in Foundation.
# ---------------------------------------------------------------------------
echo "Building $EXT_NAME.appex"
swiftc \
    Sources/AutoGainKernel.swift \
    Sources/AutoGainAudioUnit.swift \
    Sources/AutoGainViewController.swift \
    -o "$APPEX/Contents/MacOS/$EXT_NAME" \
    -module-name "$EXT_NAME" \
    -application-extension \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -framework AppKit \
    -framework AVFoundation \
    -framework AudioToolbox \
    -framework CoreAudioKit \
    -O \
    -target "$TARGET"

# ---------------------------------------------------------------------------
# 2. The container app.
# ---------------------------------------------------------------------------
echo "Building $APP_NAME"
swiftc \
    Sources/main.swift \
    -o "$BUNDLE/Contents/MacOS/$BIN_NAME" \
    -module-name "$BIN_NAME" \
    -framework AppKit \
    -framework AVFoundation \
    -O \
    -target "$TARGET"

# ---------------------------------------------------------------------------
# 3. Signing.
#
#    The appex is signed first, then the app that contains it. Signing the
#    outer bundle first would invalidate as soon as the inner one changed.
#    Ad-hoc signing is enough for a locally built plug-in; the sandbox
#    entitlement is what lets the component advertise sandboxSafe.
# ---------------------------------------------------------------------------
echo "Signing"
codesign --force --sign - --timestamp=none \
    --entitlements Entitlements.plist \
    "$APPEX"
codesign --force --sign - --timestamp=none \
    --entitlements Entitlements.plist \
    "$BUNDLE"

codesign --verify --deep --strict "$BUNDLE"

echo "Built $BUNDLE"

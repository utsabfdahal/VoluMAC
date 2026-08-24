#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/VoluMAC.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
SOURCES="$ROOT/Sources"
ENGINE_OBJECT="$BUILD/SoftwareVolumeEngine.o"

rm -rf "$BUILD"
mkdir -p "$MACOS" "$RESOURCES" "$BUILD"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT:h/LICENSE" "$RESOURCES/LICENSE"

xcrun clang++ \
    -std=c++17 \
    -fobjc-arc \
    -O2 \
    -target arm64-apple-macos14.2 \
    -c "$SOURCES/SoftwareVolumeEngine.mm" \
    -o "$ENGINE_OBJECT"

xcrun swiftc \
    -parse-as-library \
    -O \
    -target arm64-apple-macos14.2 \
    -import-objc-header "$SOURCES/VoluMAC-Bridging-Header.h" \
    -I "$SOURCES" \
    -framework AppKit \
    -framework Carbon \
    -framework CoreAudio \
    -framework QuartzCore \
    -framework SwiftUI \
    "$SOURCES/VoluMACApp.swift" \
    "$SOURCES/MediaKeyMonitor.swift" \
    "$SOURCES/OutputShortcutMonitor.swift" \
    "$SOURCES/SoftwareVolumeController.swift" \
    "$SOURCES/VolumeHUDController.swift" \
    "$ENGINE_OBJECT" \
    -lc++ \
    -o "$MACOS/VoluMAC"

codesign --force --deep --sign - "$APP"
echo "$APP"

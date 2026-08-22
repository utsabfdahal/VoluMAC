#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/Dell Audio.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
SOURCES="$ROOT/Sources"
ENGINE_OBJECT="$BUILD/SoftwareVolumeEngine.o"

rm -rf "$APP"
mkdir -p "$MACOS" "$BUILD"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"

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
    -import-objc-header "$SOURCES/DellAudioMenu-Bridging-Header.h" \
    -I "$SOURCES" \
    -framework AppKit \
    -framework CoreAudio \
    -framework QuartzCore \
    -framework SwiftUI \
    "$SOURCES/DellAudioMenu.swift" \
    "$SOURCES/MediaKeyMonitor.swift" \
    "$SOURCES/SoftwareVolumeController.swift" \
    "$SOURCES/VolumeHUDController.swift" \
    "$ENGINE_OBJECT" \
    -lc++ \
    -o "$MACOS/DellAudioMenu"

codesign --force --deep --sign - "$APP"
echo "$APP"

#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h}"
cd "$TASK_ROOT"
BUILD_DIRECTORY="${IA_BUILD_DIR:-$TASK_ROOT/.build}"
swift build -c release --scratch-path "$BUILD_DIRECTORY"
BINARY_DIR="$(swift build -c release --scratch-path "$BUILD_DIRECTORY" --show-bin-path)"
APP_DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$TASK_ROOT/Info.plist")"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TASK_ROOT/Info.plist")"
APP_DEST="${TASK_ROOT:h}/$APP_DISPLAY_NAME.app"
mkdir -p "$APP_DEST/Contents/MacOS" "$APP_DEST/Contents/Resources"
cp "$BINARY_DIR/BatteryCare" "$APP_DEST/Contents/MacOS/$APP_EXECUTABLE"
cp "$TASK_ROOT/Info.plist" "$APP_DEST/Contents/Info.plist"
if [[ -f "$TASK_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$TASK_ROOT/Resources/AppIcon.icns" "$APP_DEST/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$APP_DEST"
print "Built: $APP_DEST"

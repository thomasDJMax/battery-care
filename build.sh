#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h}"
cd "$TASK_ROOT"

# 发版用 `./build.sh --universal`（或 IA_UNIVERSAL=1）：同时构建 Apple Silicon
# 与 Intel。默认只构建当前机器架构，保持日常构建速度。
UNIVERSAL=0
case "${1:-}" in
    "") ;;
    --universal) UNIVERSAL=1 ;;
    -h|--help)
        print "Usage: $0 [--universal]"
        print "  --universal  Build a universal (arm64 + x86_64) release binary."
        exit 0 ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
esac
if [[ "${IA_UNIVERSAL:-0}" == "1" ]]; then
    UNIVERSAL=1
fi

ARCH_ARGS=()
if (( UNIVERSAL )); then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

BUILD_DIRECTORY="${IA_BUILD_DIR:-$TASK_ROOT/.build}"
swift build -c release --scratch-path "$BUILD_DIRECTORY" "${ARCH_ARGS[@]}"
BINARY_DIR="$(swift build -c release --scratch-path "$BUILD_DIRECTORY" "${ARCH_ARGS[@]}" --show-bin-path)"
APP_DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$TASK_ROOT/Info.plist")"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TASK_ROOT/Info.plist")"
APP_DEST="${IA_APP_DEST:-${TASK_ROOT:h}/$APP_DISPLAY_NAME.app}"
mkdir -p "$APP_DEST/Contents/MacOS" "$APP_DEST/Contents/Resources"
cp "$BINARY_DIR/BatteryCare" "$APP_DEST/Contents/MacOS/$APP_EXECUTABLE"
cp "$TASK_ROOT/Info.plist" "$APP_DEST/Contents/Info.plist"
if [[ -f "$TASK_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$TASK_ROOT/Resources/AppIcon.icns" "$APP_DEST/Contents/Resources/AppIcon.icns"
fi
ARCHS="$(lipo -archs "$APP_DEST/Contents/MacOS/$APP_EXECUTABLE")"
if (( UNIVERSAL )) && [[ "$ARCHS" != *arm64* || "$ARCHS" != *x86_64* ]]; then
    print -u2 "Expected a universal binary (arm64 + x86_64), got: $ARCHS"
    exit 1
fi
print "Architectures: $ARCHS"
codesign --force --deep --sign - "$APP_DEST"
print "Built: $APP_DEST"

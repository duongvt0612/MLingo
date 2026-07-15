#!/bin/zsh

set -euo pipefail

ROOT_DIR=${0:A:h:h}
BUILD_DIR="$ROOT_DIR/.build/local-rc"
OUTPUT_DIR="$ROOT_DIR/.build/release"
OUTPUT_TARGET_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
DERIVED_DATA="$ROOT_DIR/.build/xcode-derived"
PACKAGE_CACHE="$ROOT_DIR/.build/xcode-packages"
ARCHIVE_PATH="$BUILD_DIR/MLingo.xcarchive"
APP_PATH="$OUTPUT_DIR/MLingo.app"
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/MLingo.app"
ENTITLEMENTS_PATH="$BUILD_DIR/MLingo.entitlements.plist"

mkdir -p "$BUILD_DIR" "$OUTPUT_TARGET_DIR"
if [[ ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]]; then
  ln -s arm64-apple-macosx/release "$OUTPUT_DIR"
fi
if [[ ! -d "$OUTPUT_DIR" ]]; then
  print -u2 "SwiftPM release output is not a directory: $OUTPUT_DIR"
  exit 1
fi
rm -rf "$ARCHIVE_PATH" "$APP_PATH" "$ENTITLEMENTS_PATH"

xcodebuild \
  -project "$ROOT_DIR/MLingo.xcodeproj" \
  -scheme MLingo \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$PACKAGE_CACHE" \
  archive \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  EXCLUDED_ARCHS=x86_64

ditto "$ARCHIVED_APP" "$APP_PATH"

codesign --verify --deep --strict "$APP_PATH"
[[ "$(lipo -archs "$APP_PATH/Contents/MacOS/MLingo")" == "arm64" ]]
[[ "$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")" == "com.duongvt.MLingo" ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")" == "0.1.0" ]]
[[ "$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")" == "1" ]]
[[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]]
[[ -f "$APP_PATH/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]

codesign -d --entitlements - --xml "$APP_PATH" > "$ENTITLEMENTS_PATH"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS_PATH")" == "false" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.allow-jit' "$ENTITLEMENTS_PATH")" == "true" ]]
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$ENTITLEMENTS_PATH" >/dev/null 2>&1; then
  print -u2 "Unexpected get-task-allow entitlement in Release app"
  exit 1
fi

print "Local RC ready: $APP_PATH"

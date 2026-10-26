#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
PREVIEW_APP="${STATUS_DETAILS_PREVIEW_APP:-/private/tmp/goodtouchbar-030-preview/GoodTouchBarPreviewFixed.app}"
BUILD_ROOT="${STATUS_DETAILS_PREVIEW_BUILD_ROOT:-/private/tmp/goodtouchbar-030-preview/build}"
BUNDLE_ID="${STATUS_DETAILS_PREVIEW_BUNDLE_ID:-io.github.yihuirui.goodtouchbar.preview.fixed}"
[[ ! -e "$PREVIEW_APP" ]] || { print -u2 "拒绝覆盖已有预览应用：$PREVIEW_APP"; exit 2; }
case "$PREVIEW_APP" in /private/tmp/goodtouchbar-030-preview/*) ;; *) print -u2 "预览应用必须位于指定临时目录"; exit 2 ;; esac
case "$BUILD_ROOT" in /private/tmp/goodtouchbar-030-preview/*) ;; *) print -u2 "预览构建目录必须位于指定临时目录"; exit 2 ;; esac
mkdir -p "$BUILD_ROOT/module-cache"
TASK_BUILD_DIR="$BUILD_ROOT"
export TASK_BUILD_DIR
. "$ROOT/scripts/test-architecture.zsh"
mkdir -p "$PREVIEW_APP/Contents/MacOS"

swiftc -parse-as-library \
    -module-cache-path "$BUILD_ROOT/module-cache" \
    -target "$TARGET_TRIPLE" \
    -framework AppKit \
    Sources/TouchBarLearning/StatusDetailsPopover.swift \
    Tests/StatusDetailsPreviewApp.swift \
    -o "$PREVIEW_APP/Contents/MacOS/GoodTouchBarPreview"
chmod +x "$PREVIEW_APP/Contents/MacOS/GoodTouchBarPreview"
cat > "$PREVIEW_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>goodtouchbar Preview</string>
    <key>CFBundleExecutable</key><string>GoodTouchBarPreview</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>goodtouchbar Preview</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0-preview</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$PREVIEW_APP/Contents/Info.plist" >/dev/null
print "PREVIEW_APP=$PREVIEW_APP"
print "PREVIEW_BUNDLE_ID=$BUNDLE_ID"
print "PREVIEW_EXECUTABLE=$PREVIEW_APP/Contents/MacOS/GoodTouchBarPreview"

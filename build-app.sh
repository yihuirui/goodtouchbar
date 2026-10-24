#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
ARCH="$(/usr/bin/uname -m)"
OPEN_APP=0
while (( $# )); do
    case "$1" in
        --no-open) OPEN_APP=0 ;;
        --open) OPEN_APP=1 ;;
        --arch)
            shift
            (( $# )) || { print -u2 "--arch 缺少架构参数"; exit 64; }
            ARCH="$1"
            ;;
        arm64|x86_64) ARCH="$1" ;;
        --arch=arm64) ARCH=arm64 ;;
        --arch=x86_64) ARCH=x86_64 ;;
        *) print -u2 "未知参数：$1"; exit 64 ;;
    esac
    shift
done
case "$ARCH" in arm64|x86_64) ;; *) print -u2 "不支持的目标架构：$ARCH"; exit 64 ;; esac
TARGET_TRIPLE="${TARGET_TRIPLE:-$ARCH-apple-macosx13.0}"
[[ "$TARGET_TRIPLE" == "$ARCH-apple-macosx13.0" ]] || { print -u2 "TARGET_TRIPLE 与 --arch 不匹配"; exit 64; }

TASK_BUILD_DIR="${BUILD_SCRATCH_PATH:-$(mktemp -d "/private/tmp/goodtouchbar-020-${ARCH}-build.XXXXXX")}"
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:-$TASK_BUILD_DIR/module-cache}"
DIST_DIR="${DIST_OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_DIR="${APP_OUTPUT_DIR:-$DIST_DIR/$ARCH/goodtouchbar.app}"
ZIP_PATH="${ZIP_OUTPUT_PATH:-$DIST_DIR/goodtouchbar-0.2.0-$ARCH.zip}"
MANIFEST_PATH="${MANIFEST_OUTPUT_PATH:-$DIST_DIR/goodtouchbar-0.2.0-$ARCH-build-manifest.txt}"
CHECKSUM_PATH="$ZIP_PATH.sha256"
IDENTITY="${CODE_SIGN_IDENTITY:--}"
case "$TASK_BUILD_DIR" in /private/tmp/*|/private/var/folders/*/T/*) ;; *) print -u2 "构建目录必须位于临时目录：$TASK_BUILD_DIR"; exit 2 ;; esac
case "$APP_DIR" in "$DIST_DIR"/*) ;; *) print -u2 "应用产物必须放在指定 dist 目录内"; exit 2 ;; esac
case "$ZIP_PATH" in "$DIST_DIR"/*) ;; *) print -u2 "ZIP 产物必须放在指定 dist 目录内"; exit 2 ;; esac
[[ ! -e "$APP_DIR" && ! -e "$ZIP_PATH" && ! -e "$MANIFEST_PATH" && ! -e "$CHECKSUM_PATH" ]] || { print -u2 "拒绝覆盖已有发布产物"; exit 2; }
mkdir -p "$DIST_DIR" "${APP_DIR:h}" "$TASK_MODULE_CACHE"
cd "$ROOT_DIR"

swift build --disable-sandbox -c "$BUILD_CONFIGURATION" --triple "$TARGET_TRIPLE" \
    --scratch-path "$TASK_BUILD_DIR" \
    -Xswiftc -module-cache-path -Xswiftc "$TASK_MODULE_CACHE" \
    -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=/goodtouchbar" \
    -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=/goodtouchbar"

PRODUCT_DIRECTORY="$TASK_BUILD_DIR/$ARCH-apple-macosx/$BUILD_CONFIGURATION"
MAIN_BINARY="$PRODUCT_DIRECTORY/GoodTouchBar"
SENSOR_BINARY="$PRODUCT_DIRECTORY/GoodTouchSensors"
FAN_HELPER="$PRODUCT_DIRECTORY/GoodTouchFanHelper"
for binary in "$MAIN_BINARY" "$SENSOR_BINARY"; do
    [[ -x "$binary" ]] || { print -u2 "构建产物缺失：$binary"; exit 1; }
    arches=$(/usr/bin/lipo -archs "$binary")
    [[ "$arches" == "$ARCH" ]] || { print -u2 "拒绝架构不匹配的产物：$binary ($arches)"; exit 1; }
done
if [[ "$ARCH" == x86_64 ]]; then
    [[ -x "$FAN_HELPER" ]] || { print -u2 "Intel 风扇辅助程序缺失：$FAN_HELPER"; exit 1; }
    [[ "$(/usr/bin/lipo -archs "$FAN_HELPER")" == x86_64 ]] || { print -u2 "辅助服务架构错误"; exit 1; }
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$MAIN_BINARY" "$APP_DIR/Contents/MacOS/GoodTouchBar"
cp "$SENSOR_BINARY" "$APP_DIR/Contents/MacOS/GoodTouchSensors"
chmod +x "$APP_DIR/Contents/MacOS/GoodTouchBar" "$APP_DIR/Contents/MacOS/GoodTouchSensors"

# Prefix maps remove local source/scratch locations from debug metadata. Strip
# remaining debug sections before signing so distributed binaries contain no
# per-user build paths.
for binary in "$APP_DIR/Contents/MacOS/GoodTouchBar" "$APP_DIR/Contents/MacOS/GoodTouchSensors"; do
    /usr/bin/strip -S "$binary"
done

if [[ "$ARCH" == x86_64 ]]; then
    mkdir -p "$APP_DIR/Contents/Library/LaunchServices"
    cp "$FAN_HELPER" "$APP_DIR/Contents/Library/LaunchServices/io.github.yihuirui.goodtouchbar.fan-helper"
    chmod +x "$APP_DIR/Contents/Library/LaunchServices/io.github.yihuirui.goodtouchbar.fan-helper"
    /usr/bin/strip -S "$APP_DIR/Contents/Library/LaunchServices/io.github.yihuirui.goodtouchbar.fan-helper"
    cp -R "$ROOT_DIR/Resources/FanControl" "$APP_DIR/Contents/Resources/FanControl"
else
    [[ ! -e "$APP_DIR/Contents/Library/LaunchServices" && ! -e "$APP_DIR/Contents/Resources/FanControl" ]] || { print -u2 "ARM bundle 不得包含 Intel 特权辅助服务或安装器资源"; exit 1; }
fi
cp -R "$ROOT_DIR/Resources/WorkBuddyRetry" "$APP_DIR/Contents/Resources/WorkBuddyRetry"
cp -R "$ROOT_DIR/Presets" "$APP_DIR/Contents/Resources/Presets"
cp -R "$ROOT_DIR/Licenses" "$APP_DIR/Contents/Resources/Licenses"
cp "$ROOT_DIR/THIRD-PARTY-NOTICES.md" "$APP_DIR/Contents/Resources/"

/usr/bin/codesign --force --options runtime --identifier io.github.yihuirui.goodtouchbar.sensors --sign "$IDENTITY" "$APP_DIR/Contents/MacOS/GoodTouchSensors" >/dev/null
if [[ "$ARCH" == x86_64 ]]; then
    /usr/bin/codesign --force --options runtime --identifier io.github.yihuirui.goodtouchbar.fan-helper --sign "$IDENTITY" "$APP_DIR/Contents/Library/LaunchServices/io.github.yihuirui.goodtouchbar.fan-helper" >/dev/null
fi
/usr/bin/codesign --force --options runtime --identifier io.github.yihuirui.goodtouchbar --sign "$IDENTITY" "$APP_DIR/Contents/MacOS/GoodTouchBar" >/dev/null
/usr/bin/codesign --force --options runtime --sign "$IDENTITY" "$APP_DIR" >/dev/null

/bin/zsh "$ROOT_DIR/scripts/validate-build.sh" "$APP_DIR" "$ARCH"
if [[ "$ARCH" == x86_64 ]]; then
    /bin/sh "$APP_DIR/Contents/Resources/FanControl/install-helper.sh" --preflight "$APP_DIR" "$(/usr/bin/id -u)"
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

if [[ "$IDENTITY" == "-" ]]; then
    SIGNING_NOTE="ad-hoc; not notarized; Gatekeeper may block opening"
else
    SIGNING_NOTE="developer identity; not notarized"
fi

tree_digest() {
    local root="$1"
    shift
    (
        cd "$root"
        {
            for task_source_path in "$@"; do
                if [[ -d "$task_source_path" ]]; then /usr/bin/find "$task_source_path" -type f -print
                elif [[ -f "$task_source_path" ]]; then print -r -- "$task_source_path"
                fi
            done
        } | LC_ALL=C /usr/bin/sort | while IFS= read -r task_source_file; do /usr/bin/shasum -a 256 "$task_source_file"; done \
          | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
    )
}
SOURCE_CODE_SHA256="$(tree_digest "$ROOT_DIR" Sources)"
SOURCE_RESOURCE_SHA256="$(tree_digest "$ROOT_DIR" Resources Presets Licenses Info.plist Package.swift THIRD-PARTY-NOTICES.md)"
MAIN_ARCHES=$(/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/GoodTouchBar")
SENSOR_ARCHES=$(/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/GoodTouchSensors")
if [[ "$ARCH" == x86_64 ]]; then
    HELPER_ARCHES=$(/usr/bin/lipo -archs "$APP_DIR/Contents/Library/LaunchServices/io.github.yihuirui.goodtouchbar.fan-helper")
else
    HELPER_ARCHES=omitted
fi
APP_RELATIVE="${APP_DIR#$DIST_DIR/}"
cat > "$MANIFEST_PATH" <<EOF
name=goodtouchbar
version=0.2.0
build=2
bundle=io.github.yihuirui.goodtouchbar
target=$TARGET_TRIPLE
main_arches=$MAIN_ARCHES
sensor_arches=$SENSOR_ARCHES
helper_arches=$HELPER_ARCHES
source_code_sha256=$SOURCE_CODE_SHA256
source_resource_sha256=$SOURCE_RESOURCE_SHA256
signature=$SIGNING_NOTE
app=$APP_RELATIVE
zip=${ZIP_PATH:t}
EOF
(cd "$DIST_DIR" && /usr/bin/shasum -a 256 "${ZIP_PATH:t}" > "${CHECKSUM_PATH:t}")
print "已生成：$APP_RELATIVE"
print "已生成：${ZIP_PATH#$DIST_DIR/}"
print "签名状态：$SIGNING_NOTE"
if (( OPEN_APP )); then
    open "$APP_DIR"
else
    exit 0
fi

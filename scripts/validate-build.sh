#!/bin/zsh
set -euo pipefail

APP_DIR="${1:?usage: validate-build.sh /path/to/goodtouchbar.app arm64|x86_64}"
ARCH="${2:?usage: validate-build.sh /path/to/goodtouchbar.app arm64|x86_64}"
SOURCE_DIR="${0:A:h:h}"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
MAIN_EXECUTABLE="$APP_DIR/Contents/MacOS/GoodTouchBar"
SENSOR_EXECUTABLE="$APP_DIR/Contents/MacOS/GoodTouchSensors"
HELPER_EXECUTABLE="$APP_DIR/Contents/Library/LaunchServices/io.github.yihuirui.goodtouchbar.fan-helper"
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { print -u2 "FAIL: unsupported architecture: $ARCH"; exit 64; }
[[ -d "$APP_DIR" && -f "$INFO_PLIST" && -x "$MAIN_EXECUTABLE" && -x "$SENSOR_EXECUTABLE" ]] || { print -u2 "FAIL: app bundle or required executable missing"; exit 1; }
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
bundle_identifier=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")
display_name=$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$INFO_PLIST")
bundle_name=$(/usr/bin/plutil -extract CFBundleName raw -o - "$INFO_PLIST")
short_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")
bundle_version=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")
touchbar_default=$(/usr/bin/plutil -extract GoodTouchBarTouchBarDefault raw -o - "$INFO_PLIST")
[[ "$bundle_identifier" == "io.github.yihuirui.goodtouchbar" && "$display_name" == "goodtouchbar" && "$bundle_name" == "goodtouchbar" ]] || { print -u2 "FAIL: brand or bundle identity mismatch"; exit 1; }
[[ "$short_version" == "0.3.1" && "$bundle_version" == "4" && "$touchbar_default" == "auto" ]] || { print -u2 "FAIL: version or Auto mode metadata mismatch"; exit 1; }

for binary in "$MAIN_EXECUTABLE" "$SENSOR_EXECUTABLE"; do
    [[ "$(/usr/bin/lipo -archs "$binary")" == "$ARCH" ]] || { print -u2 "FAIL: binary architecture differs from $ARCH: $binary"; exit 1; }
    /usr/bin/codesign --verify --strict "$binary"
    details=$(/usr/bin/codesign -dv --verbose=4 "$binary" 2>&1)
    [[ "$details" == *"flags="*"runtime"* ]] || { print -u2 "FAIL: Hardened Runtime missing: $binary"; exit 1; }
    entitlements=$(/usr/bin/codesign -d --entitlements - "$binary" 2>/dev/null)
    [[ -z "$entitlements" ]] || { print -u2 "FAIL: unexpected entitlements: $binary"; exit 1; }
done

main_identifier=$(/usr/bin/codesign -dv --verbose=4 "$MAIN_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '/^Identifier=/{print $2}')
sensor_identifier=$(/usr/bin/codesign -dv --verbose=4 "$SENSOR_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '/^Identifier=/{print $2}')
[[ "$main_identifier" == "io.github.yihuirui.goodtouchbar" && "$sensor_identifier" == "io.github.yihuirui.goodtouchbar.sensors" ]] || { print -u2 "FAIL: main or sensor code identifier mismatch"; exit 1; }

if [[ "$ARCH" == x86_64 ]]; then
    [[ -x "$HELPER_EXECUTABLE" && -d "$APP_DIR/Contents/Resources/FanControl" ]] || { print -u2 "FAIL: Intel bundle is missing fan helper resources"; exit 1; }
    [[ "$(/usr/bin/lipo -archs "$HELPER_EXECUTABLE")" == x86_64 ]] || { print -u2 "FAIL: helper architecture must be x86_64"; exit 1; }
    /usr/bin/codesign --verify --strict "$HELPER_EXECUTABLE"
    helper_identifier=$(/usr/bin/codesign -dv --verbose=4 "$HELPER_EXECUTABLE" 2>&1 | /usr/bin/awk -F= '/^Identifier=/{print $2}')
    [[ "$helper_identifier" == "io.github.yihuirui.goodtouchbar.fan-helper" ]] || { print -u2 "FAIL: helper code identifier mismatch"; exit 1; }
else
    [[ ! -e "$HELPER_EXECUTABLE" && ! -e "$APP_DIR/Contents/Resources/FanControl" ]] || { print -u2 "FAIL: ARM bundle contains privileged Intel fan helper or installer resources"; exit 1; }
fi
for binary in "$MAIN_EXECUTABLE" "$SENSOR_EXECUTABLE"; do
    if /usr/bin/grep -a -E -q '/Users/[^/[:space:]]+/|/private/tmp/|/private/var/folders/|/var/folders/' "$binary"; then
        print -u2 "FAIL: executable contains a local user or build path"; exit 1
    fi
done
if [[ "$ARCH" == x86_64 ]] && /usr/bin/grep -a -E -q '/Users/[^/[:space:]]+/|/private/tmp/|/private/var/folders/|/var/folders/' "$HELPER_EXECUTABLE"; then
    print -u2 "FAIL: helper contains a local user or build path"; exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
source_build=$(/usr/bin/awk -F'= ' '/public static let fallback/{print $2}' "$SOURCE_DIR/Sources/SystemMonitoring/AppBuild.swift")
[[ "$bundle_version" == "$source_build" ]] || { print -u2 "FAIL: Info.plist build number and AppBuild fallback differ"; exit 1; }
for resource in Presets/专注AI.json Presets/系统监控.json; do
    [[ -f "$APP_DIR/Contents/Resources/$resource" ]] || { print -u2 "FAIL: bundled preset missing: $resource"; exit 1; }
done
print "PASS: goodtouchbar 0.3.1 build 4, $ARCH app architecture, signatures, runtime policy, and presets verified"

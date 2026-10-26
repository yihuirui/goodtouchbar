#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
STAGING_DIST="${1:?usage: promote-release.sh /private/tmp/goodtouchbar-030-*/dist arm64|x86_64}"
ARCH="${2:?usage: promote-release.sh /private/tmp/goodtouchbar-030-*/dist arm64|x86_64}"
case "$ARCH" in arm64|x86_64) ;; *) print -u2 "Unsupported architecture: $ARCH"; exit 64 ;; esac
case "$STAGING_DIST" in /private/tmp/goodtouchbar-030-*/dist) ;; *) print -u2 "发布暂存目录必须属于本工作包的 /private/tmp/goodtouchbar-030-*"; exit 2 ;; esac
DESTINATION="$ROOT_DIR/dist"
STAGING_APP="$STAGING_DIST/0.3.0/$ARCH/goodtouchbar.app"
STAGING_ZIP="$STAGING_DIST/goodtouchbar-0.3.0-$ARCH.zip"
STAGING_MANIFEST="$STAGING_DIST/goodtouchbar-0.3.0-$ARCH-build-manifest.txt"
STAGING_CHECKSUM="$STAGING_ZIP.sha256"
DEST_APP="$DESTINATION/0.3.0/$ARCH/goodtouchbar.app"
DEST_ZIP="$DESTINATION/goodtouchbar-0.3.0-$ARCH.zip"
DEST_MANIFEST="$DESTINATION/goodtouchbar-0.3.0-$ARCH-build-manifest.txt"
DEST_CHECKSUM="$DEST_ZIP.sha256"
[[ -d "$STAGING_APP" && -f "$STAGING_ZIP" && -f "$STAGING_MANIFEST" && -f "$STAGING_CHECKSUM" ]] || { print -u2 "暂存发布目录缺少 App、ZIP、manifest 或 checksum"; exit 2; }
[[ ! -e "$DEST_APP" && ! -e "$DEST_ZIP" && ! -e "$DEST_MANIFEST" && ! -e "$DEST_CHECKSUM" ]] || { print -u2 "拒绝覆盖已有交付物"; exit 2; }
grep -Eq "^app=0\.3\.0/$ARCH/goodtouchbar\.app$" "$STAGING_MANIFEST"
grep -Eq "^zip=goodtouchbar-0\.3\.0-$ARCH\.zip$" "$STAGING_MANIFEST"
grep -Eq '^signature=(ad-hoc|developer identity);' "$STAGING_MANIFEST"
if grep -Eq '/Users/|/private/|CODE_SIGN_IDENTITY=' "$STAGING_MANIFEST" "$STAGING_CHECKSUM"; then
    print -u2 "发布 sidecar 包含本机路径或证书身份信息"; exit 1
fi
(cd "$STAGING_DIST" && /usr/bin/shasum -a 256 -c "${STAGING_CHECKSUM:t}")
/bin/zsh "$ROOT_DIR/scripts/validate-build.sh" "$STAGING_APP" "$ARCH"
if [[ "$ARCH" == x86_64 ]]; then
    /bin/sh "$STAGING_APP/Contents/Resources/FanControl/install-helper.sh" --preflight "$STAGING_APP" "$(/usr/bin/id -u)"
fi
/usr/bin/unzip -tq "$STAGING_ZIP"

mkdir -p "${DEST_APP:h}"
/usr/bin/ditto "$STAGING_APP" "$DEST_APP"
/bin/cp "$STAGING_ZIP" "$DEST_ZIP"
/bin/cp "$STAGING_MANIFEST" "$DEST_MANIFEST"
/bin/cp "$STAGING_CHECKSUM" "$DEST_CHECKSUM"
(cd "$DESTINATION" && /usr/bin/shasum -a 256 -c "${DEST_CHECKSUM:t}")
/usr/bin/unzip -tq "$DEST_ZIP"
/bin/zsh "$ROOT_DIR/scripts/validate-build.sh" "$DEST_APP" "$ARCH"
if [[ "$ARCH" == x86_64 ]]; then
    /bin/sh "$DEST_APP/Contents/Resources/FanControl/install-helper.sh" --preflight "$DEST_APP" "$(/usr/bin/id -u)"
fi
print "PASS: $ARCH release artifacts promoted without changing pre-existing dist files"

#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Kisetsu"
BUNDLE_ID="com.kisetsu.mobile"
SCHEME="KisetsuMobile"
CONFIGURATION="Release"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/AppleClient/KisetsuMobile.xcodeproj"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/.build/KisetsuMobileIPA"
APP_BUNDLE="$BUILD_DIR/Build/Products/Release-iphoneos/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/$APP_NAME"
IPA_PATH="$DIST_DIR/$APP_NAME.ipa"

show_help() {
  cat <<'HELP'
用法：./script/build_mobile_ipa.sh

构建 Kisetsu iPhone Release 版本，并生成：
  dist/Kisetsu.ipa

当前脚本只封装未签名 IPA。安装前需要使用你自己的证书或签名工具签名。
HELP
}

case "${1:-}" in
  "") ;;
  -h|--help)
    show_help
    exit 0
    ;;
  *)
    show_help >&2
    exit 2
    ;;
esac

command -v xcodebuild >/dev/null || {
  echo "错误：没有找到 xcodebuild，请先安装并选择完整 Xcode。" >&2
  exit 1
}
command -v ditto >/dev/null || {
  echo "错误：没有找到 ditto。" >&2
  exit 1
}

echo "==> 构建 iPhone Release 应用"
rm -rf "$BUILD_DIR"
mkdir -p "$DIST_DIR"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "$APP_BUNDLE" || ! -x "$APP_BINARY" ]]; then
  echo "错误：Release 构建完成后没有找到有效的 $APP_NAME.app。" >&2
  exit 1
fi

ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Info.plist")"
if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "错误：Bundle ID 为 $ACTUAL_BUNDLE_ID，预期为 $BUNDLE_ID。" >&2
  exit 1
fi

ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_BINARY")"
if [[ " $ARCHITECTURES " != *" arm64 "* ]]; then
  echo "错误：真机应用缺少 arm64 架构，当前为：$ARCHITECTURES" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kisetsu-ipa.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo "==> 封装 IPA"
mkdir -p "$STAGING_DIR/Payload"
/usr/bin/ditto "$APP_BUNDLE" "$STAGING_DIR/Payload/$APP_NAME.app"
rm -f "$IPA_PATH"
(
  cd "$STAGING_DIR"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$IPA_PATH"
)

/usr/bin/unzip -tq "$IPA_PATH" >/dev/null
if ! /usr/bin/unzip -Z1 "$IPA_PATH" | /usr/bin/grep -q "^Payload/$APP_NAME.app/Info.plist$"; then
  echo "错误：IPA 中缺少 Payload/$APP_NAME.app/Info.plist。" >&2
  exit 1
fi

IPA_SIZE="$(/usr/bin/stat -f '%z' "$IPA_PATH")"
IPA_SIZE_MB="$(/usr/bin/awk -v bytes="$IPA_SIZE" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 }')"

echo
echo "未签名 IPA 封装完成"
echo "  路径：$IPA_PATH"
echo "  Bundle ID：$ACTUAL_BUNDLE_ID"
echo "  架构：$ARCHITECTURES"
echo "  大小：$IPA_SIZE_MB MB"
echo "  签名：未签名（安装前需要使用你的证书或签名工具签名）"

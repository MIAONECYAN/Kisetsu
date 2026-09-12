#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Kisetsu"
BUNDLE_ID="com.kisetsu.app"
MIN_SYSTEM_VERSION="15.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/AppleClient"
DIST_DIR="$ROOT_DIR/dist"
if [[ "$MODE" == "--fixture" ]]; then
  DIST_DIR="/private/tmp/Kisetsu-DesktopFixture"
  BUNDLE_ID="com.kisetsu.desktop.fixture"
  export KISETSU_DESKTOP_USE_FIXTURES=1
fi
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
PKG_INFO="$APP_CONTENTS/PkgInfo"

if [[ "$MODE" != "--fixture" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

swift build --package-path "$PACKAGE_DIR" --product "$APP_NAME"
BUILD_BINARY="$(swift build --package-path "$PACKAGE_DIR" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$PACKAGE_DIR/Resources/Kisetsu.icns" "$APP_RESOURCES/Kisetsu.icns"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>Kisetsu.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Kisetsu 需要连接你在设置中配置的局域网后端。</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' >"$PKG_INFO"

# Bind Info.plist and the stable bundle identifier to the executable so macOS
# can persist Local Network permission for this app across rebuilds.
/usr/bin/codesign --force --deep --sign - --identifier "$BUNDLE_ID" \
  --entitlements "$PACKAGE_DIR/Kisetsu.entitlements" "$APP_BUNDLE"

open_app() {
  local open_args=(-n "$APP_BUNDLE")
  if [[ -n "${KISETSU_COLOR_SCHEME:-}" ]]; then
    open_args+=(--env "KISETSU_COLOR_SCHEME=$KISETSU_COLOR_SCHEME")
  fi
  if [[ -n "${KISETSU_DESKTOP_USE_FIXTURES:-}" ]]; then
    open_args+=(--env "KISETSU_DESKTOP_USE_FIXTURES=$KISETSU_DESKTOP_USE_FIXTURES")
  fi
  if [[ -n "${KISETSU_DESKTOP_INITIAL_SECTION:-}" ]]; then
    open_args+=(--env "KISETSU_DESKTOP_INITIAL_SECTION=$KISETSU_DESKTOP_INITIAL_SECTION")
  fi
  if [[ "$MODE" == "--fixture" && -n "${KISETSU_DESKTOP_ORGANIZE_FIXTURE_URL:-}" ]]; then
    open_args+=(--env "KISETSU_DESKTOP_ORGANIZE_FIXTURE_URL=$KISETSU_DESKTOP_ORGANIZE_FIXTURE_URL")
  fi
  /usr/bin/open "${open_args[@]}"
}

case "$MODE" in
  run|--fixture)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--fixture]" >&2
    exit 2
    ;;
esac

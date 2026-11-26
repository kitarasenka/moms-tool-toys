#!/bin/bash
# Собирает WifiMom.app и кладёт в /Applications (или ~/Applications, если нет прав).
# Приложение запускает wifimom.mjs из этой папки проекта тем node, что найден сейчас —
# после переезда проекта или смены версии node запустите скрипт снова.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
NODE="$(command -v node || true)"
[ -n "$NODE" ] || { echo "node не найден в PATH"; exit 1; }
NODE="$(cd "$(dirname "$NODE")" && pwd -P)/$(basename "$NODE")"

DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
APP="$DEST/WifiMom.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Сборка…"
B="$TMP/WifiMom.app/Contents"
mkdir -p "$B/MacOS" "$B/Resources"
swiftc -O "$HERE/main.swift" -o "$B/MacOS/WifiMom"

swift "$HERE/icon.swift" "$TMP/icon.png"
mkdir "$TMP/icon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/icon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/icon.iconset" -o "$B/Resources/WifiMom.icns"

cat > "$B/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WifiMom</string>
  <key>CFBundleDisplayName</key><string>WifiMom</string>
  <key>CFBundleIdentifier</key><string>local.wifimom</string>
  <key>CFBundleExecutable</key><string>WifiMom</string>
  <key>CFBundleIconFile</key><string>WifiMom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>WifimomNode</key><string>$NODE</string>
  <key>WifimomScript</key><string>$ROOT/wifimom.mjs</string>
</dict></plist>
EOF
codesign --force --deep -s - "$TMP/WifiMom.app" 2>/dev/null

# Старая сборка называлась wifimom.app — закрываем и её (bundle id тот же, данные WKWebView сохраняются).
if pgrep -ixq wifimom; then osascript -e 'quit app id "local.wifimom"' || true; sleep 1; fi
rm -rf "$DEST/wifimom.app" "$APP"
mv "$TMP/WifiMom.app" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Готово: $APP (node: $NODE)"

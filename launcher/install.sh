#!/bin/bash
# Собирает «Mom's Tool Toys.app» — общий запуск инструментов — и кладёт в /Applications
# (или ~/Applications, если нет прав). Сами инструменты ставятся своими скриптами (см. ../install.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
APP="$DEST/Mom's Tool Toys.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Сборка лаунчера…"
B="$TMP/Mom's Tool Toys.app/Contents"
mkdir -p "$B/MacOS" "$B/Resources"
swiftc -O -parse-as-library "$HERE/main.swift" -o "$B/MacOS/MomsToolToys"

# Иконка лаунчера: icon.png (1024×1024) → .icns
mkdir "$TMP/icon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$HERE/icon.png" --out "$TMP/icon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$HERE/icon.png" --out "$TMP/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/icon.iconset" -o "$B/Resources/AppIcon.icns"

# Картинки для окна: шапка и иконки инструментов (256 px хватает для карточек)
sips -z 256 256 "$ROOT/assets/moms-tool-toys.png" --out "$B/Resources/hero.png" >/dev/null
sips -z 256 256 "$ROOT/wifimom/app/icon.png" --out "$B/Resources/wifimom.png" >/dev/null
sips -z 256 256 "$ROOT/perfmom/Resources/AppIcon.png" --out "$B/Resources/perfmom.png" >/dev/null

cat > "$B/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Mom's Tool Toys</string>
  <key>CFBundleDisplayName</key><string>Mom's Tool Toys</string>
  <key>CFBundleIdentifier</key><string>local.momstooltoys</string>
  <key>CFBundleExecutable</key><string>MomsToolToys</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$TMP/Mom's Tool Toys.app" 2>/dev/null

if pgrep -xq MomsToolToys; then osascript -e 'quit app id "local.momstooltoys"' || true; sleep 1; fi
rm -rf "$APP"
mv "$TMP/Mom's Tool Toys.app" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Готово: $APP"

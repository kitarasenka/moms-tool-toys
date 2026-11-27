#!/bin/zsh
# Собирает SafetyMom.app в ./build и подписывает ad-hoc подписью.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Сборка (release)…"
swift build -c release

APP="build/SafetyMom.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/SafetyMom" "$APP/Contents/MacOS/SafetyMom"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Переводы: Resources/<язык>.lproj (ключ — русский текст); язык выбирает macOS.
cp -R Resources/*.lproj "$APP/Contents/Resources/"

echo "▸ Иконка…"
# Resources/AppIcon.png (1024×1024) → AppIcon.icns
TMP=$(mktemp -d)
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

codesign --force --sign - "$APP" >/dev/null
echo "✓ Готово: $APP"
echo "  Запуск: open $APP"

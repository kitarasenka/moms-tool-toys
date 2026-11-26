#!/bin/zsh
# Собирает PerfMon.app в ./build и подписывает ad-hoc подписью.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Сборка (release)…"
swift build -c release

APP="build/PerfMon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/PerfMon" "$APP/Contents/MacOS/PerfMon"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "▸ Рисую иконку…"
    TMP=$(mktemp -d)
    swift Scripts/make_icon.swift "$TMP/icon.png"
    ICONSET="$TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
    rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null
echo "✓ Готово: $APP"
echo "  Запуск: open $APP"

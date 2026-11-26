#!/bin/bash
# Ставит всё разом: WifiMom, PerfMom и общий запуск «Mom's Tool Toys» — в /Applications
# (или ~/Applications, если нет прав). Каждый инструмент можно ставить и отдельно своим скриптом.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

echo "━━ WifiMom"
"$ROOT/wifimom/app/install.sh"

echo "━━ PerfMom"
"$ROOT/perfmom/Scripts/build_app.sh"
# Закрыть запущенную копию (до переименования процесс назывался PerfMon; bundle id тот же).
if pgrep -xq PerfMom || pgrep -xq PerfMon; then osascript -e 'quit app id "local.perfmon.app"' || true; sleep 1; fi
rm -rf "$DEST/PerfMon.app" "$DEST/PerfMom.app"
cp -R "$ROOT/perfmom/build/PerfMom.app" "$DEST/PerfMom.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/PerfMom.app" >/dev/null 2>&1 || true
echo "Готово: $DEST/PerfMom.app"

echo "━━ Mom's Tool Toys"
"$ROOT/launcher/install.sh"

echo
echo "Всё установлено. Запуск: open -a \"Mom's Tool Toys\""

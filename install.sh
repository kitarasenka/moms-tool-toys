#!/bin/bash
# Ставит всё разом: WifiMom, PerfMom, CleanerMom и общий запуск «Mom's Tool Toys» — в /Applications
# (или ~/Applications, если нет прав). Каждый инструмент можно ставить и отдельно своим скриптом.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

echo "━━ WifiMom"
"$ROOT/wifimom/app/install.sh"

# Собранное приложение из <папка>/build → $DEST (закрыв запущенную копию).
install_built() {  # <путь к .app> <bundle id> [старое имя .app]
  local src="$1" id="$2" name; name="$(basename "$1")"
  if pgrep -fq "$DEST/$name/Contents/MacOS/"; then
    osascript -e "quit app id \"$id\"" || true; sleep 1
  fi
  rm -rf "$DEST/$name" ${3:+"$DEST/$3"}
  cp -R "$src" "$DEST/$name"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/$name" >/dev/null 2>&1 || true
  echo "Готово: $DEST/$name"
}

echo "━━ PerfMom"
"$ROOT/perfmom/Scripts/build_app.sh"
# До переименования приложение называлось PerfMon (bundle id остался прежним).
pgrep -xq PerfMon && { osascript -e 'quit app id "local.perfmon.app"' || true; sleep 1; }
install_built "$ROOT/perfmom/build/PerfMom.app" local.perfmon.app PerfMon.app

echo "━━ CleanerMom"
"$ROOT/cleanermom/Scripts/build_app.sh"
install_built "$ROOT/cleanermom/build/CleanerMom.app" local.cleanermom

echo "━━ Mom's Tool Toys"
"$ROOT/launcher/install.sh"

echo
echo "Всё установлено. Запуск: open -a \"Mom's Tool Toys\""

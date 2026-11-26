#!/bin/bash
# Двойной щелчок в Finder — собрать и установить все инструменты и «Mom's Tool Toys».
# Открывается в Терминале, проверяет, что нужно для сборки, и запускает ./install.sh.
cd "$(dirname "$0")" || exit 1

pause() { echo; read -r -n 1 -s -p "Нажмите любую клавишу, чтобы закрыть окно…"; echo; }

echo "Mom's Tool Toys — установка"
echo

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "Для сборки нужны инструменты разработчика Apple (Command Line Tools)."
  echo "Сейчас откроется окно их установки — нажмите «Установить», дождитесь конца"
  echo "и снова откройте этот файл."
  xcode-select --install 2>/dev/null
  pause; exit 1
fi

# Node нужен только WifiMom; если запускать из Finder, nvm/Homebrew могут быть не в PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
if ! command -v node >/dev/null 2>&1; then
  echo "Не найден Node.js — он нужен для WifiMom."
  echo "Установите его с https://nodejs.org (кнопка LTS) и снова откройте этот файл."
  pause; exit 1
fi

if ./install.sh; then
  echo
  echo "Готово! Открываю Mom's Tool Toys…"
  open -a "Mom's Tool Toys" 2>/dev/null
else
  echo
  echo "Что-то пошло не так — сообщение об ошибке выше."
fi
pause

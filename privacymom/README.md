# PrivacyMom

Кто и к чему имеет доступ на Mac — в стиле Mom's Tool Toys (SwiftUI, macOS 14+).
Разрешения приложений, включённые камера и микрофон, следы в браузерах, запомненные сети Wi-Fi.

## Разделы

- **Разрешения** (⌘1) — читает базы разрешений macOS (TCC) только на чтение: пользовательскую
  `~/Library/Application Support/com.apple.TCC/TCC.db` и системную `/Library/Application Support/com.apple.TCC/TCC.db`.
  Сводка «доступ к камере / к микрофону / запись экрана / полный доступ к диску», слева — службы
  (камера, микрофон, запись экрана, универсальный доступ, мониторинг ввода, полный доступ к диску,
  Документы/Загрузки/Рабочий стол, съёмные тома, контакты, календари, напоминания, фото, Bluetooth,
  автоматизация с целевым приложением, …; незнакомые — по сырому имени), справа — приложения с иконкой,
  «разрешено/запрещено/ограничено» и датой. Действия: «Открыть в Настройках» (нужная панель Privacy_*)
  и «Сбросить разрешение» (`tccutil reset <Служба> <bundle id>`, с подтверждением; приложение спросит снова).
- **Сейчас** (⌘2) — каждые 2 с: включена ли камера (CoreMediaIO) и микрофон (CoreAudio), с именами
  устройств. Журнал включений/выключений, пока приложение открыто:
  `~/Library/Application Support/PrivacyMom/sensors.jsonl`, показываются последние 7 дней.
  Разрешение на камеру и микрофон не нужно — устройства не открываются.
- **Браузеры** (⌘3) — Safari, Chrome, Firefox, Яндекс, Edge, Brave, Arc, Opera: размер истории, cookies и
  кэша по всем профилям, кнопки «Очистить историю», «Очистить cookies», «Очистить кэш» (только у закрытого
  браузера, с подтверждением). Какие файлы:
  - Chromium: `<профиль>/History`, `History-journal`; `Cookies`, `Cookies-journal`, `Network/Cookies*`;
    кэш — содержимое `~/Library/Caches/<браузер>/<профиль>`.
  - Firefox: только `cookies.sqlite*` и `cache2`. История лежит в `places.sqlite` вместе с закладками —
    её не трогаем, подсказываем очистить в самом Firefox.
  - Safari (нужен полный доступ к диску): `~/Library/Safari/History.db*`, `Cookies.binarycookies`
    (в контейнере Safari и в `~/Library/Cookies`), кэш `~/Library/Caches/com.apple.Safari`.
- **Сети Wi-Fi** (⌘4) — запомненные сети (`networksetup -listpreferredwirelessnetworks`), текущая отмечена
  (её имя берётся из `system_profiler`: `networksetup` в новых macOS его прячет). «Забыть» —
  `networksetup -removepreferredwirelessnetwork` с паролем администратора.

## Безопасность

- Базы разрешений открываются только на чтение (`mode=ro&immutable=1`), схема определяется по `PRAGMA table_info`.
- История и cookies уходят **в Корзину** (можно вернуть), кэш удаляется сразу. Удаляется только то, что лежит
  строго внутри папки браузера; пароли, закладки, автозаполнение, `places.sqlite` в цели не попадают никогда
  (`BrowserScanner.protectedNames`, проверка — `--selftest`).
- Имена сетей и bundle id не подставляются в текст команд: `tccutil` запускается напрямую с аргументами,
  а для `networksetup` имя сети приходит в `osascript` через `argv` и экранируется `quoted form of`.

## Полный доступ к диску

Без него закрыты базы разрешений и всё, что связано с Safari. PrivacyMom туда не стучится (кроме попытки
открыть TCC.db — она просто завершается ошибкой, без запроса на экране), показывает плашку со ссылкой на
настройки и перечитывает данные, когда вы возвращаетесь в окно. После пересборки ad-hoc подпись меняется —
разрешение, возможно, придётся выдать заново.

## Сборка и проверка

```sh
./Scripts/build_app.sh                   # build/PrivacyMom.app (иконка — Resources/AppIcon.png)
swift run PrivacyMom --permissions       # разрешения по службам или «нет полного доступа»
swift run PrivacyMom --sensors           # камера и микрофон сейчас, имена устройств
swift run PrivacyMom --browsers          # размеры истории/cookies/кэша, без удаления
swift run PrivacyMom --selftest          # TCC на временной базе, очистка на поддельных профилях, экранирование имён сетей
open build/PrivacyMom.app --args --section browsers    # раздел: permissions|now|browsers|wifi
open build/PrivacyMom.app --args --demo-tcc /path/TCC.db   # показать подготовленную базу вместо настоящих (сброс отключён)
```

## Устройство

```
Sources/PrivacyMom/
  PrivacyMomApp.swift   точка входа, меню, аргументы запуска, консольные режимы
  SelfTest.swift        --selftest (всё во временной папке)
  AppState.swift        состояние разделов (PermissionsStore, SensorStore, BrowserStore, WifiStore)
  Model/
    Core.swift          размеры, пути, полный доступ к диску, имена приложений, запуск команд
    TCC.swift           службы, чтение TCC.db через SQLite3, сброс через tccutil
    Sensors.swift       камера/микрофон через CoreMediaIO/CoreAudio, журнал sensors.jsonl
    Browsers.swift      каталог браузеров, пути профилей, безопасная очистка
    Wifi.swift          запомненные сети, текущая сеть, «Забыть»
  Views/                экраны и общие компоненты (fillAvailable — см. комментарий в Components.swift)
```

## Языки

Русский, английский, китайский (упрощённый), немецкий, французский и арабский.
macOS выбирает язык автоматически. Для отдельного приложения его можно изменить в «Системные настройки → Основные → Язык и регион».

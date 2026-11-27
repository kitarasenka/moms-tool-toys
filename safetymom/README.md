# SafetyMom

«Проверка Mac» в стиле Mom's Tool Toys (SwiftUI, macOS 14+). Светофор безопасности: всё ли включено,
есть ли резервная копия, не разрешено ли сайтам присылать «Ваш Mac заражён!», не стоят ли подозрительные
расширения, не подменены ли прокси, DNS и hosts. Каждый пункт — простыми словами: что это значит и что сделать,
и кнопка, которая открывает нужное место в Системных настройках. Сам SafetyMom настройки macOS не меняет.

## Разделы

- **Проверка** (⌘1) — итог сверху (зелёный / жёлтый / красный по худшему пункту) и 11 проверок, худшие наверху:
  - **Обновления macOS** — есть ли непоставленное обновление текущей версии; давно ли Mac искал обновления;
    не устарела ли версия (Apple чинит безопасность только у трёх последних; после 15 идёт 26, поэтому поколения
    считаются по порядку, а не вычитанием номеров).
  - **Автоматические обновления** — «Ответы системы безопасности и системные файлы» (красный, если выключены),
    проверка обновлений, автообновление приложений App Store.
  - **FileVault**, **файрвол**, **Gatekeeper**, **SIP** — включены ли.
  - **Time Machine** — настроена ли, когда была последняя копия (до 7 дней — зелёный, до 30 — жёлтый, дольше — красный),
    не выключены ли автоматические копии.
  - **Пароль после сна** — когда спрашивается пароль и не горит ли экран вечно.
  - **Вход без пароля** — автовход.
  - **Удалённый доступ** — удалённый вход (SSH), общий экран / удалённое управление, общий доступ к файлам.
  - **XProtect** — версия и дата базы встроенного антивируса.
- **Браузеры** (⌘2), две вкладки:
  - **Уведомления от сайтов** — каким сайтам разрешено присылать уведомления: знакомые сервисы — зелёные, незнакомые —
    жёлтые, похожие на спам (слова вроде prize/push/allow, домены .xyz/.top/.online…) — красные. Сверху — объяснение
    главного сценария: «Ваш Mac заражён!» — это уведомление сайта, а не вирус. В Chromium-браузерах
    (Chrome, Яндекс, Edge, Brave, Arc, Opera, Vivaldi) SafetyMom ставит сайту «Запретить» сам — по одному или
    «Запретить все незнакомые». В Firefox и Safari — показывает и подсказывает, где снять разрешение.
  - **Расширения** — Chromium (все профили), Firefox, Safari. Пометки: «видит все сайты», «меняет прокси», «отладчик»,
    «управляет расширениями», «связь с программой на Mac», «не из магазина», «режим разработчика», «поставлено программой»,
    «недавно». Красное — не из магазина и с широкими правами; жёлтое — что-то одно из этого. Удаление — вручную
    на странице расширений браузера (кнопка открывает её).
- **Сеть и профили** (⌘3) — прокси (HTTP/HTTPS/SOCKS/PAC), DNS-серверы (роутер и известные сервисы — зелёные,
  незнакомые и 127.0.0.1 — жёлтые), нестандартные строки `/etc/hosts` (блокировка рекламы — норма, перенаправление
  банка или блокировка обновлений Apple — тревога), профили конфигурации и MDM. Автозагрузку не дублирует —
  кнопка открывает её в PerfMom (`--section startup`).

## Откуда данные

Без пароля администратора и без запросов на экране:

| Проверка | Источник |
|---|---|
| FileVault | `fdesetup status` |
| Файрвол | `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate` |
| Gatekeeper / SIP | `spctl --status` / `csrutil status` |
| Обновления | `/Library/Preferences/com.apple.SoftwareUpdate.plist` (`RecommendedUpdates`, `LastSuccessfulDate`, `CriticalUpdateInstall`, `ConfigDataInstall`, `AutomaticCheckEnabled`), `com.apple.commerce.plist` (`AutoUpdate`) |
| Time Machine | `/Library/Preferences/com.apple.TimeMachine.plist` (`Destinations[].SnapshotDates`, `AutoBackup`) и `tmutil destinationinfo`. `tmutil latestbackup` не используется — он монтирует диск и без него падает |
| Пароль после сна | `sysadminctl -screenLock status`, `defaults -currentHost read com.apple.screensaver idleTime`, `pmset -g` |
| Автовход | `/Library/Preferences/com.apple.loginwindow.plist` (`autoLoginUser`) |
| Удалённый доступ | пробное подключение к 127.0.0.1: порты 22, 5900, 3283, 445 (`systemsetup -getremotelogin` требует админа) |
| XProtect | `/Library/Apple/System/Library/CoreServices/XProtect.bundle` — версия и дата файлов |
| Прокси / DNS | `CFNetworkCopySystemProxySettings`, `SCDynamicStore` `State:/Network/Global/DNS` (запасной путь — `scutil --dns`) |
| Профили | `system_profiler SPConfigurationProfileDataType -json` (видит и системные, в отличие от `profiles list` без sudo), `profiles status -type enrollment` |
| Chromium | `Local State` (имена профилей), `Secure Preferences` + `Preferences` → `extensions.settings`, `manifest.json` и `_locales` для имён `__MSG_…__`, `profile.content_settings.exceptions.notifications` (`setting` 1 — разрешено) |
| Firefox | `extensions.json` (`location == app-profile`, без системных `@mozilla.org`), `permissions.sqlite` (`desktop-notification`, только чтение, `immutable=1`) |
| Safari | `pluginkit -mAvv -p com.apple.Safari.web-extension` / `com.apple.Safari.extension`; уведомления — `~/Library/Safari/UserNotificationPermissions.plist`, только с полным доступом к диску (формат не документирован, читается осторожно) |

Команды запускаются без оболочки и с тайм-аутом (по умолчанию 10 с) — зависшая команда превращается
в «не удалось проверить», а не в вечную загрузку. Все проверки идут параллельно, вся проверка — около секунды.

## Безопасность

- Настройки macOS SafetyMom не меняет: только читает и открывает Системные настройки (`x-apple.systempreferences:`).
- Единственная запись — «Запретить уведомления» в `Preferences` профиля Chromium:
  только при **закрытом** браузере (иначе он перезапишет файл при выходе — кнопка «Закрыть …» шлёт штатное «Завершить»);
  перед записью — копия прежнего файла в `~/Library/Application Support/SafetyMom/Backups/` (0600, хранятся последние 30);
  запись атомарная (временный файл рядом + `replaceItemAt`), результат перепроверяется чтением; меняется только
  `setting` (→ 2, «Запретить») и `last_modified` у выбранных сайтов, остальное сохраняется. `Secure Preferences` не трогается.
- Расширения не удаляются — только показываются.
- Никаких запросов TCC: `~/Library/Containers` не читается; `~/Library/Safari` — только если уже есть полный доступ к диску
  (проверяется попыткой прочитать папку: без доступа это просто ошибка).
- В сеть ничего не отправляется.

## Сборка и проверка

```sh
./Scripts/build_app.sh                    # build/SafetyMom.app (иконка — Resources/AppIcon.png)
swift run SafetyMom --selftest            # разбор ответов команд, правила светофора, браузерные профили и запрет уведомлений на временной папке
swift run SafetyMom --checks              # те же проверки в Терминале (только чтение)
open build/SafetyMom.app --args --demo    # выдуманные данные в памяти (для скриншотов); кнопки ничего не меняют
open build/SafetyMom.app --args --demo --section browsers --tab extensions
```

`--section checks|browsers|network`, `--tab notifications|extensions`.

## Устройство

```
Sources/SafetyMom/
  SafetyMomApp.swift   точка входа, окно, меню ⌘1…⌘3 / ⌘R, аргументы запуска, `--checks`
  AppState.swift       состояние разделов, загрузка в фоне, запрет уведомлений, «Закрыть браузер»
  SelfTest.swift       `--selftest` и демо-данные для `--demo`
  Model/
    Core.swift         Shell с тайм-аутом, plist, пути, полный доступ к диску, ссылки на Системные настройки
    Checks.swift       11 проверок: сбор (gather…) отдельно от разбора (чистые функции — их и проверяет selftest)
    Browsers.swift     браузеры, профили, расширения, уведомления, NotificationRevoker
    Network.swift      прокси, DNS, /etc/hosts, профили конфигурации, MDM
  Views/               Проверка, Браузеры, Сеть и профили (fillAvailable — см. Components.swift)
```

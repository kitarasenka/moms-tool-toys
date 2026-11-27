# Mom's Tool Toys

<p align="center"><img src="assets/moms-tool-toys.png" width="360" alt="Mom's Tool Toys"></p>

Маленькие инструменты для домашнего Mac. Каждый живёт в своей папке и собирается отдельно.

**[Посмотреть, что умеет каждое приложение →](https://kitarasenka.github.io/moms-tool-toys/)** — лендинг с интерактивными окнами: можно пощёлкать разделы и кнопки прямо в браузере (исходник — [docs/](docs/)).

| Папка | Приложение | Что делает |
|---|---|---|
| [wifimom/](wifimom/) | WifiMom | Мониторинг домашнего Wi-Fi: отличает сбои Wi-Fi от сбоев провайдера, карта покрытия, устройства в сети, замер скорости. Node без зависимостей + окно на WKWebView. |
| [perfmom/](perfmom/) | PerfMom | Монитор производительности (SwiftUI): процессы, дерево, автозагрузка, эвристическая проверка безопасности. Подробности — [perfmom/README.md](perfmom/README.md). |
| [cleanermom/](cleanermom/) | CleanerMom | Уборка Mac: кэши, журналы, временные файлы и Корзина одной кнопкой, крупные файлы, удаление приложений со следами, обслуживание. Подробности — [cleanermom/README.md](cleanermom/README.md). |
| [diskmom/](diskmom/) | DiskMom | Диски: карта того, что занимает место (кольцевая диаграмма с переходом внутрь), поиск дубликатов, состояние и извлечение дисков. Подробности — [diskmom/README.md](diskmom/README.md). |
| [privacymom/](privacymom/) | PrivacyMom | Приватность: кто имеет доступ к камере, микрофону, экрану и файлам (со сбросом разрешений), включены ли сейчас камера и микрофон, очистка истории и cookies браузеров, сохранённые сети Wi-Fi. Подробности — [privacymom/README.md](privacymom/README.md). |
| [batterymom/](batterymom/) | BatteryMom | Батарея: здоровье, циклы, ёмкость, история заряда, расход энергии по приложениям, заряд мыши, клавиатуры и AirPods; значок в строке меню. Подробности — [batterymom/README.md](batterymom/README.md). |
| [clipmom/](clipmom/) | ClipMom | История буфера обмена: текст, ссылки, картинки и файлы, поиск, закрепление, быстрая панель ⇧⌘V, пароли из менеджеров паролей не записываются. Подробности — [clipmom/README.md](clipmom/README.md). |
| [helpmom/](helpmom/) | HelpMom | Позвать на помощь: отчёт «что у меня за Mac и что с ним» со светофором (скопировать, сохранить, отправить), помощники с FaceTime, Сообщениями и Telegram одной кнопкой, как показать экран, шпаргалки на частые проблемы. Подробности — [helpmom/README.md](helpmom/README.md). |
| [safetymom/](safetymom/) | SafetyMom | Проверка Mac светофором: обновления, FileVault, файрвол, Gatekeeper, Time Machine, пароль после сна, удалённый доступ; сайты с разрешёнными уведомлениями (откуда «Ваш Mac заражён!») с запретом в один клик, подозрительные расширения браузеров, прокси, DNS, hosts и профили. Подробности — [safetymom/README.md](safetymom/README.md). |
| [keymom/](keymom/) | KeyMom | Раскладка: «ghbdtn» → «привет» по ⇧⌘ Пробел в любом приложении (выделение или последнее слово, раскладка переключается сама), окно для длинных текстов, RU/EN в строке меню и у курсора, предупреждение о Caps Lock в поле пароля. Подробности — [keymom/README.md](keymom/README.md). |
| [desktopmom/](desktopmom/) | DesktopMom | Порядок на Рабочем столе и в Загрузках: раскладывает снимки экрана по папкам месяцев, убирает остальное по типам, находит установщики уже установленных приложений и давно забытые файлы; журнал с «Вернуть». Подробности — [desktopmom/README.md](desktopmom/README.md). |
| [launcher/](launcher/) | Mom's Tool Toys | Общий запуск: окно с карточками инструментов (Wifi, Perf, Cleaner…), видно, что запущено; ⌘1…⌘9 и ⌘0 — открыть инструмент; в шапке — GitHub и Telegram разработчика [@marstut](https://t.me/marstut). |

## Установка

Проще всего — двойной щелчок по **`Установить.command`** в Finder: он проверит, что есть инструменты
разработчика Apple и Node.js (подскажет, если нет), соберёт всё, установит и откроет Mom's Tool Toys.
Если macOS скажет, что файл от неустановленного разработчика, — щелчок правой кнопкой → «Открыть».

Или из Терминала:

```sh
./install.sh                    # всё разом в /Applications: все инструменты и Mom's Tool Toys
```

Дальше запускать через **Mom's Tool Toys** (Spotlight, Launchpad или `open -a "Mom's Tool Toys"`).

Каждый инструмент собирается и отдельно:

```sh
wifimom/app/install.sh          # WifiMom.app → /Applications; CLI: wifimom (ссылка в ~/.local/bin)
perfmom/Scripts/build_app.sh    # perfmom/build/PerfMom.app (в /Applications кладёт ./install.sh)
<tool>/Scripts/build_app.sh     # cleanermom, diskmom, privacymom, batterymom, clipmom, helpmom,
                                # safetymom, keymom, desktopmom → <tool>/build/<App>.app
                                # (в /Applications их кладёт ./install.sh)
launcher/install.sh             # Mom's Tool Toys.app → /Applications
```

`wifimom/app/install.sh` вшивает путь к проекту в приложение — после переноса папки запустите его снова.

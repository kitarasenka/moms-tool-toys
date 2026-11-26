# Mom's Tool Toys

<p align="center"><img src="assets/moms-tool-toys.png" width="360" alt="Mom's Tool Toys"></p>

Маленькие инструменты для домашнего Mac. Каждый живёт в своей папке и собирается отдельно.

| Папка | Приложение | Что делает |
|---|---|---|
| [wifimom/](wifimom/) | WifiMom | Мониторинг домашнего Wi-Fi: отличает сбои Wi-Fi от сбоев провайдера, карта покрытия, устройства в сети, замер скорости. Node без зависимостей + окно на WKWebView. |
| [perfmom/](perfmom/) | PerfMom | Монитор производительности (SwiftUI): процессы, дерево, автозагрузка, эвристическая проверка безопасности. Подробности — [perfmom/README.md](perfmom/README.md). |
| [launcher/](launcher/) | Mom's Tool Toys | Общий запуск: окно с карточками инструментов, видно, что запущено; ⌘1 / ⌘2 — открыть WifiMom / PerfMom. |

## Установка

```sh
./install.sh                    # всё разом в /Applications: WifiMom, PerfMom и Mom's Tool Toys
```

Дальше запускать через **Mom's Tool Toys** (Spotlight, Launchpad или `open -a "Mom's Tool Toys"`).

Каждый инструмент собирается и отдельно:

```sh
wifimom/app/install.sh          # WifiMom.app → /Applications; CLI: wifimom (ссылка в ~/.local/bin)
perfmom/Scripts/build_app.sh    # perfmom/build/PerfMom.app (в /Applications кладёт ./install.sh)
launcher/install.sh             # Mom's Tool Toys.app → /Applications
```

`wifimom/app/install.sh` вшивает путь к проекту в приложение — после переноса папки запустите его снова.

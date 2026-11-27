import Foundation

// Обслуживание: системные команды, которые иногда помогают «оживить» Mac.
// Команды — только константы отсюда; с правами администратора macOS сама спросит пароль.

struct MaintenanceTask: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let needsAdmin: Bool
    let command: String
    var tool: String? = nil      // запуск без оболочки, когда пароль не нужен
    var args: [String] = []

    func run() -> Shell.Result {
        if needsAdmin { return Shell.runAsAdmin(command) }
        if let tool { return Shell.run(tool, args) }
        return Shell.run("/bin/sh", ["-c", command])
    }

    static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static let all: [MaintenanceTask] = [
        MaintenanceTask(
            id: "dns", title: String(localized: "Сбросить кэш DNS"),
            detail: String(localized: "Помогает, когда сайт переехал или открывается старая версия, а у других всё работает."),
            icon: "network", needsAdmin: true,
            command: "dscacheutil -flushcache; killall -HUP mDNSResponder"),
        MaintenanceTask(
            id: "ram", title: String(localized: "Освободить оперативную память"),
            detail: String(localized: "Сбрасывает дисковый кэш в памяти. Полезно перед тяжёлой задачей; пару секунд Mac может притормозить."),
            icon: "memorychip", needsAdmin: true, command: "/usr/sbin/purge"),
        MaintenanceTask(
            id: "launchservices", title: String(localized: "Перестроить базу Launch Services"),
            detail: String(localized: "Убирает дубли в меню «Открыть с помощью» и неверные иконки файлов."),
            icon: "square.stack.3d.up", needsAdmin: false, command: "",
            tool: lsregister, args: ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"]),
        MaintenanceTask(
            id: "quicklook", title: String(localized: "Сбросить Quick Look"),
            detail: String(localized: "Помогает, если по пробелу не показываются превью или миниатюры файлов устарели."),
            icon: "eye", needsAdmin: false, command: "/usr/bin/qlmanage -r && /usr/bin/qlmanage -r cache"),
        MaintenanceTask(
            id: "spotlight", title: String(localized: "Переиндексировать Spotlight"),
            detail: String(localized: "Если поиск не находит файлы. Индекс строится заново в фоне — это может занять час и нагрузить Mac."),
            icon: "magnifyingglass", needsAdmin: true, command: "/usr/bin/mdutil -E /"),
    ]
}

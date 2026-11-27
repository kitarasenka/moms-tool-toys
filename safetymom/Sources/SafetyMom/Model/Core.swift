import AppKit
import Foundation

// MARK: - Формат

enum Fmt {
    static let ru = Locale(identifier: "ru_RU")

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(.dateTime.day().month(.wide).year().locale(ru))
    }

    static func dateTime(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.wide).hour().minute().locale(ru))
    }

    static func time(_ d: Date) -> String { d.formatted(.dateTime.hour().minute().locale(ru)) }

    /// «3 дня назад», «вчера».
    static func ago(_ d: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(d) < 60 { return "только что" }
        let f = RelativeDateTimeFormatter()
        f.locale = ru
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: now)
    }

    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(n) \(plural(n, one, few, many))"
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        return (m10 == 1 && m100 != 11) ? one : ((2...4).contains(m10) && !(12...14).contains(m100) ? few : many)
    }
}

// MARK: - Пути

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    static let library = home.appendingPathComponent("Library", isDirectory: true)
    static let appSupport = library.appendingPathComponent("Application Support", isDirectory: true)
    static let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL

    /// Своя папка: ~/Library/Application Support/SafetyMom (резервные копии настроек браузеров).
    static let ownData = appSupport.appendingPathComponent("SafetyMom", isDirectory: true)
    static let backups = ownData.appendingPathComponent("Backups", isDirectory: true)

    static func pretty(_ p: String) -> String {
        p.hasPrefix(home.path + "/") ? "~" + p.dropFirst(home.path.count) : p
    }
}

// MARK: - Полный доступ к диску

enum FullDiskAccess {
    /// ~/Library/Safari закрыта без полного доступа к диску. Проверяем настоящим чтением папки:
    /// без доступа это просто ошибка, без запроса на экране.
    static var granted: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: Paths.library.appendingPathComponent("Safari").path)) != nil
    }

    static func openSettings() {
        Settings.open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }
}

// MARK: - Системные настройки и приложения

/// Куда отправить человека, чтобы исправить найденное.
struct SettingsLink: Hashable, Sendable {
    var title: String
    var url: String

    static let fileVault = SettingsLink(title: "Открыть FileVault", url: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault")
    static let firewall = SettingsLink(title: "Открыть настройки файрвола", url: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")
    static let security = SettingsLink(title: "Открыть «Конфиденциальность и безопасность»", url: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Security")
    static let softwareUpdate = SettingsLink(title: "Открыть «Обновление ПО»", url: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
    static let lockScreen = SettingsLink(title: "Открыть «Экран блокировки»", url: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")
    static let users = SettingsLink(title: "Открыть «Пользователи и группы»", url: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")
    static let sharing = SettingsLink(title: "Открыть «Общий доступ»", url: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")
    static let timeMachine = SettingsLink(title: "Открыть Time Machine", url: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")
    static let network = SettingsLink(title: "Открыть «Сеть»", url: "x-apple.systempreferences:com.apple.Network-Settings.extension")
    static let profiles = SettingsLink(title: "Открыть «Профили»", url: "x-apple.systempreferences:com.apple.Profiles-Settings.extension")
    static let notifications = SettingsLink(title: "Открыть «Уведомления»", url: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    static let fullDisk = SettingsLink(title: "Открыть «Полный доступ к диску»", url: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
}

enum Settings {
    static func open(_ link: SettingsLink) { open(link.url) }
    static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

enum Apps {
    static func url(_ bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Штатное «Завершить» (браузер сам сохранит вкладки).
    static func quit(_ bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
    }

    static func open(_ bundleID: String, arguments: [String] = []) {
        guard let url = url(bundleID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.arguments = arguments
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }

    /// Открыть адрес (например, chrome://extensions) в конкретном браузере.
    static func open(_ address: String, in bundleID: String) {
        guard let app = url(bundleID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let u = URL(string: address) {
            NSWorkspace.shared.open([u], withApplicationAt: app, configuration: cfg) { _, _ in }
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in }
        }
    }

    static func icon(_ bundleID: String) -> NSImage? {
        url(bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

// MARK: - Команды

enum Shell {
    struct Result: Sendable {
        var ok: Bool
        var output: String
        var timedOut = false
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    /// Запускает программу без оболочки (аргументы не интерпретируются), с ограничением по времени:
    /// зависшая команда не подвесит проверку — через `timeout` секунд она завершается.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 10) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return Result(ok: false, output: error.localizedDescription) }

        // Читаем параллельно, чтобы большой вывод не заполнил канал и не остановил команду.
        let box = Box()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = exited.wait(timeout: .now() + 1)
        }
        _ = read.wait(timeout: .now() + 2)
        let out = String(decoding: box.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(ok: !timedOut && p.terminationStatus == 0, output: out, timedOut: timedOut)
    }
}

// MARK: - Файлы настроек

enum Plist {
    /// Словарь из plist-файла или nil (нет файла, нет доступа). Без запросов на экране.
    static func read(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Можно ли прочитать файл (есть и доступен) — чтобы отличить «нет настройки» от «нет доступа».
    static func readable(_ path: String) -> Bool { FileManager.default.isReadableFile(atPath: path) }
}

extension Dictionary where Key == String, Value == Any {
    func bool(_ k: String) -> Bool? {
        if let b = self[k] as? Bool { return b }
        if let n = self[k] as? NSNumber { return n.boolValue }
        if let s = self[k] as? String { return ["1", "true", "yes"].contains(s.lowercased()) }
        return nil
    }

    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
}

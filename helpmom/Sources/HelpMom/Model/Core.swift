import AppKit
import Foundation

// MARK: - Формат

enum Fmt {
    static let ru = Locale(identifier: "ru_RU")

    /// «111,9 ГБ», «512 МБ». Диск — десятичные единицы (как в Finder), память — двоичные (`binary: true`, «32 ГБ»).
    static func bytes(_ n: Int64, binary: Bool = false) -> String {
        let base: Double = binary ? 1024 : 1000
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var v = Double(n), i = 0
        while abs(v) >= base && i < units.count - 1 { v /= base; i += 1 }
        let digits = (i <= 1 || v >= 100 || v == v.rounded()) ? 0 : 1
        return "\(v.formatted(.number.precision(.fractionLength(digits)).locale(ru))) \(units[i])"
    }

    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        let w = (m10 == 1 && m100 != 11) ? one : ((2...4).contains(m10) && !(12...14).contains(m100) ? few : many)
        return "\(n) \(w)"
    }

    /// «12 дней 3 ч», «5 ч 20 мин», «12 мин».
    static func uptime(_ s: TimeInterval) -> String {
        let m = Int(s / 60), h = m / 60, d = h / 24
        if d > 0 { return "\(count(d, "день", "дня", "дней")) \(h % 24) ч" }
        if h > 0 { return "\(h) ч \(m % 60) мин" }
        return "\(max(m, 1)) мин"
    }

    static func dateTime(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(ru))
    }

    static func dayMonth(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.wide).locale(ru))
    }

    static func percent(_ v: Double) -> String { "\(Int(v.rounded())) %" }
}

// MARK: - Команды

enum Shell {
    /// Запускает программу без оболочки; через `timeout` секунд процесс завершается.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - sysctl

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func int(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == 4 {
            var v: Int32 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return Int64(v)
        }
        var v: Int64 = 0
        size = 8
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return v
    }

    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    static func swapUsed() -> Int64? {
        var sw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &sw, &size, nil, 0) == 0 else { return nil }
        return Int64(sw.xsu_used)
    }
}

// MARK: - Системные настройки и приложения

enum SystemLinks {
    static func settings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    static let network = "com.apple.Network-Settings.extension"
    static let wifi = "com.apple.wifi-settings-extension"
    static let keyboard = "com.apple.Keyboard-Settings.extension"
    static let notifications = "com.apple.Notifications-Settings.extension"
    static let sharing = "com.apple.Sharing-Settings.extension"
    static let storage = "com.apple.settings.Storage"
    static let softwareUpdate = "com.apple.Software-Update-Settings.extension"

    /// Открыть системное приложение по пути (Мониторинг системы, Снимок экрана, FaceTime…).
    static func openApp(_ path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
    }

    static let activityMonitor = "/System/Applications/Utilities/Activity Monitor.app"
    static let screenshot = "/System/Applications/Utilities/Screenshot.app"
    static let faceTime = "/System/Applications/FaceTime.app"
    static let messages = "/System/Applications/Messages.app"
    static let screenSharing = "/System/Library/CoreServices/Applications/Screen Sharing.app"

    /// Системное окно «Перезагрузить?» (то же, что в меню  → «Перезагрузить…»): с подтверждением и отменой.
    static func showRestartDialog() {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"loginwindow\" to «event aevtrrst»")?.executeAndReturnError(&err)
    }
}

/// Соседние инструменты Mom's Tool Toys — ищем только по bundle id.
struct SiblingTool: Identifiable, Hashable {
    let id: String
    let name: String

    static let wifi = SiblingTool(id: "local.wifimom", name: "WifiMom")
    static let perf = SiblingTool(id: "local.perfmon.app", name: "PerfMom")
    static let cleaner = SiblingTool(id: "local.cleanermom", name: "CleanerMom")
    static let disk = SiblingTool(id: "local.diskmom", name: "DiskMom")
    static let safety = SiblingTool(id: "local.safetymom", name: "SafetyMom")
    static let key = SiblingTool(id: "local.keymom", name: "KeyMom")
    static let desktop = SiblingTool(id: "local.desktopmom", name: "DesktopMom")

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    var isInstalled: Bool { url != nil }

    func open() {
        guard let url else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
}

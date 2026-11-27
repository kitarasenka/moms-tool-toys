import AppKit
import Foundation

// MARK: - Формат

enum Fmt {
    /// «2 ч 05 мин», «45 мин».
    static func minutes(_ m: Int) -> String {
        let h = m / 60, mm = m % 60
        if h == 0 { return String(localized: "\(mm) мин") }
        return mm == 0 ? String(localized: "\(h) ч") : String(localized: "\(h) ч \(String(format: "%02d", mm)) мин")
    }

    static func duration(_ seconds: Double) -> String { minutes(Int((seconds / 60).rounded())) }

    static func watts(_ w: Double, digits: Int = 1) -> String {
        String(localized: "\(w.formatted(.number.precision(.fractionLength(digits)).locale(L10n.locale))) Вт")
    }

    static func number(_ v: Double, digits: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(L10n.locale))
    }

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale))
    }

    static func time(_ d: Date) -> String { d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)) }

    static func ago(_ d: Date?) -> String {
        guard let d else { return String(localized: "ещё не обновлялось") }
        return d.formatted(.relative(presentation: .named).locale(L10n.locale))
    }

    static func processes(_ n: Int) -> String { String(localized: "\(n) процессов") }
}

// MARK: - Команды

enum Shell {
    struct Result: Sendable {
        var ok: Bool
        var output: Data
        var pid: Int32
        var text: String { String(decoding: output, as: UTF8.self) }
    }

    /// Запускает программу без оболочки. Через `timeout` секунд процесс принудительно завершается.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 30) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return Result(ok: false, output: Data(), pid: 0) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return Result(ok: p.terminationStatus == 0, output: data, pid: p.processIdentifier)
    }
}

// MARK: - Системные настройки

enum SystemSettings {
    /// Настройки → Аккумулятор (предел зарядки, оптимизированная зарядка, режим энергосбережения).
    static func openBattery() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openBluetooth() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }
}

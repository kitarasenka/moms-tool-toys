import AppKit
import Foundation

// MARK: - Формат

enum Fmt {
    /// «2 ч 05 мин», «45 мин».
    static func minutes(_ m: Int) -> String {
        let h = m / 60, mm = m % 60
        if h == 0 { return "\(mm) мин" }
        return mm == 0 ? "\(h) ч" : "\(h) ч \(String(format: "%02d", mm)) мин"
    }

    static func duration(_ seconds: Double) -> String { minutes(Int((seconds / 60).rounded())) }

    static func watts(_ w: Double, digits: Int = 1) -> String {
        "\(w.formatted(.number.precision(.fractionLength(digits)))) Вт"
    }

    static func number(_ v: Double, digits: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(digits)))
    }

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(date: .long, time: .omitted)
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    static func ago(_ d: Date?) -> String {
        guard let d else { return "ещё не обновлялось" }
        return d.formatted(.relative(presentation: .named))
    }

    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        let w = (m10 == 1 && m100 != 11) ? one : ((2...4).contains(m10) && !(12...14).contains(m100) ? few : many)
        return "\(n.formatted()) \(w)"
    }
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

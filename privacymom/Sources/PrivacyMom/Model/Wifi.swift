import Foundation

// MARK: - Запомненные сети Wi-Fi

enum WifiNetworks {
    static let networksetup = "/usr/sbin/networksetup"

    /// Устройство Wi-Fi (обычно en0) из `networksetup -listallhardwareports`.
    static func device() -> String? {
        parseDevice(Shell.run(networksetup, ["-listallhardwareports"]).output)
    }

    static func parseDevice(_ out: String) -> String? {
        var port: String?
        for line in out.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("Hardware Port:") { port = String(line.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("Device:"), let p = port, p == "Wi-Fi" || p == "AirPort" {
                return String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func preferred(device: String) -> Shell.Result {
        Shell.run(networksetup, ["-listpreferredwirelessnetworks", device])
    }

    /// Строки после заголовка «Preferred networks on en0:», по одной сети, с табуляцией в начале.
    static func parsePreferred(_ out: String) -> [String] {
        var lines = out.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("Preferred networks on") { lines.removeFirst() }
        return lines.compactMap { l in
            guard l.hasPrefix("\t") else { return nil }
            let s = String(l.dropFirst())
            return s.isEmpty ? nil : s
        }
    }

    /// Текущая сеть. `networksetup -getairportnetwork` и `ipconfig` в новых macOS прячут имя без доступа
    /// к геолокации, а `system_profiler` его показывает (работает несколько секунд).
    static func current() -> String? {
        let r = Shell.run("/usr/sbin/system_profiler", ["SPAirPortDataType"])
        return parseCurrent(r.output)
    }

    static func parseCurrent(_ out: String) -> String? {
        guard let range = out.range(of: "Current Network Information:") else { return nil }
        let rest = out[range.upperBound...]
        for line in rest.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(":") { return String(t.dropLast()) }
            break
        }
        return nil
    }

    /// «Забыть» сеть. Нужен пароль администратора — его спросит macOS. Имя сети и устройство
    /// передаются в `osascript` как аргументы, в текст скрипта не подставляются.
    static func forget(_ ssid: String, device: String) -> Shell.Result {
        let r = Shell.runViaAppleScript(networksetup, ["-removepreferredwirelessnetwork", device, ssid], admin: true)
        if r.ok, r.output.hasPrefix("Error") || r.output.hasSuffix("not found.") || r.output.contains("was not found") {
            return .init(ok: false, output: r.output)
        }
        return r
    }
}

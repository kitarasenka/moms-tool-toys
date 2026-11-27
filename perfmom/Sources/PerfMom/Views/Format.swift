import Foundation

enum Fmt {
    private static let units = [String(localized: "Б"), String(localized: "КБ"), String(localized: "МБ"), String(localized: "ГБ"), String(localized: "ТБ")]

    static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }

    static func bytes(_ value: Double) -> String {
        var v = max(0, value)
        var i = 0
        while v >= 1024, i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return String(localized: "\(Int(v)) Б") }
        let digits = v < 10 ? 2 : (v < 100 ? 1 : 0)
        return v.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(L10n.locale)) + " " + units[i]
    }

    static func rate(_ v: Double?) -> String {
        guard let v else { return "—" }
        return bytes(v) + String(localized: "/с")
    }

    static func percent(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(L10n.locale))
    }

    static func cpuTime(_ s: Double) -> String {
        let t = Int(s)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        let centi = Int((s - Double(t)) * 100)
        let sep = L10n.locale.decimalSeparator ?? "."
        return String(format: "%d:%02d", m, sec) + sep + String(format: "%02d", centi)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let t = Int(max(0, interval))
        let d = t / 86_400, h = (t % 86_400) / 3600, m = (t % 3600) / 60
        if d > 0 { return String(localized: "\(d) д \(h) ч \(m) мин") }
        if h > 0 { return String(localized: "\(h) ч \(m) мин") }
        if m > 0 { return String(localized: "\(m) мин") }
        return String(localized: "\(t) с")
    }

    static func dateTime(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale))
    }

    static func number(_ n: Int) -> String { n.formatted(.number.locale(L10n.locale)) }
}

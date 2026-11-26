import Foundation

enum Fmt {
    private static let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]

    static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }

    static func bytes(_ value: Double) -> String {
        var v = max(0, value)
        var i = 0
        while v >= 1024, i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return "\(Int(v)) Б" }
        let digits = v < 10 ? 2 : (v < 100 ? 1 : 0)
        return v.formatted(.number.precision(.fractionLength(digits)).grouping(.never)) + " " + units[i]
    }

    static func rate(_ v: Double?) -> String {
        guard let v else { return "—" }
        return bytes(v) + "/с"
    }

    static func percent(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(1)).grouping(.never))
    }

    static func cpuTime(_ s: Double) -> String {
        let t = Int(s)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        let centi = Int((s - Double(t)) * 100)
        return String(format: "%d:%02d,%02d", m, sec, centi)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let t = Int(max(0, interval))
        let d = t / 86_400, h = (t % 86_400) / 3600, m = (t % 3600) / 60
        if d > 0 { return "\(d) д \(h) ч \(m) мин" }
        if h > 0 { return "\(h) ч \(m) мин" }
        if m > 0 { return "\(m) мин" }
        return "\(t) с"
    }

    static func dateTime(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .standard)
    }

    static func number(_ n: Int) -> String { n.formatted() }
}

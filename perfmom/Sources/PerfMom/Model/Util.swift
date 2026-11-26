import Darwin
import Foundation

/// Превращает C-массив фиксированной длины (импортированный в Swift как кортеж) в строку.
func cString<T>(tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let end = raw.firstIndex(of: 0) ?? raw.count
        return String(decoding: raw[..<end], as: UTF8.self)
    }
}

func cString(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

enum MachTime {
    /// На Apple Silicon счётчики времени CPU идут в тиках mach (125/3 нс), на Intel — в наносекундах.
    static let secondsPerTick: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1_000_000_000
    }()

    static func now() -> Double { Double(mach_continuous_time()) * secondsPerTick }
}

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return cString(buf)
    }

    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }
}

enum PathTools {
    /// Самый внешний .app в пути — для иконки (у helper-процессов это родительское приложение).
    static func outermostApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// Самый внутренний .app — для информации о пакете конкретного процесса.
    static func innermostApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/", options: .backwards) else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}

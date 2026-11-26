import AppKit
import Foundation

// MARK: - Формат

enum Fmt {
    /// Байты как в Finder (десятичные единицы, локаль системы).
    static func bytes(_ v: Int64) -> String { v.formatted(.byteCount(style: .file)) }

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        let w = (m10 == 1 && m100 != 11) ? one : ((2...4).contains(m10) && !(12...14).contains(m100) ? few : many)
        return "\(n.formatted()) \(w)"
    }

    static func files(_ n: Int) -> String { count(n, "файл", "файла", "файлов") }

    static func seconds(_ t: TimeInterval) -> String { String(format: "%.1f с", t) }

    static func percent(_ v: Double) -> String { v.formatted(.percent.precision(.fractionLength(0))) }
}

// MARK: - Пути

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    static let library = home.appendingPathComponent("Library", isDirectory: true)
    static let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL

    static func inHome(_ relative: String) -> URL { home.appendingPathComponent(relative, isDirectory: true) }

    /// /Users/имя/Documents → ~/Documents для показа пользователю.
    static func pretty(_ url: URL) -> String { pretty(url.path) }

    static func pretty(_ p: String) -> String {
        if p == home.path { return "~" }
        return p.hasPrefix(home.path + "/") ? "~" + p.dropFirst(home.path.count) : p
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// `inner` лежит строго внутри `outer` (не совпадает с ним).
    static func isStrictlyInside(_ inner: URL, _ outer: URL) -> Bool {
        isStrictlyInside(inner.standardizedFileURL.path, outer.standardizedFileURL.path)
    }

    static func isStrictlyInside(_ i: String, _ o: String) -> Bool {
        let prefix = o.hasSuffix("/") ? o : o + "/"
        return i.hasPrefix(prefix) && i.count > prefix.count
    }
}

// MARK: - Полный доступ к диску

enum FullDiskAccess {
    /// ~/Library/Safari есть на любом Mac и закрыт TCC — прочитать его можно только с полным доступом.
    /// Проверка тихая: без доступа система просто отказывает, без запроса.
    static var granted: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: Paths.library.appendingPathComponent("Safari").path)) != nil
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Корзина

/// Перенос в Корзину. В проверках подменяется на перенос в папку песочницы.
struct Trasher: Sendable {
    var move: @Sendable (URL) throws -> Void

    static let system = Trasher { url in
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
    }

    /// Для `--selftest`: «Корзина» — обычная папка, настоящая Корзина не засоряется.
    static func folder(_ dir: URL) -> Trasher {
        Trasher { url in
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
    }
}

// MARK: - Команды

enum Shell {
    /// Запускает программу без оболочки (аргументы не интерпретируются). Возвращает stdout.
    static func run(_ tool: String, _ args: [String]) -> (ok: Bool, output: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (false, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, data)
    }
}

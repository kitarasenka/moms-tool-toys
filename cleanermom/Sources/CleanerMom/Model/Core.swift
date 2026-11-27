import AppKit
import Foundation

// MARK: - Размер на диске

enum DiskSize {
    private static let fileKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Сколько места реально занимает объект (как «На диске» в Finder). Ссылки не разыменовываются.
    static func allocated(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = fileKeys.union([.isDirectoryKey, .isSymbolicLinkKey])
        guard let v = try? url.resourceValues(forKeys: keys), v.isSymbolicLink != true else { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(fileKeys),
                                              options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            guard let r = try? f.resourceValues(forKeys: fileKeys), r.isRegularFile == true else { continue }
            total += Int64(r.totalFileAllocatedSize ?? r.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Размеры нескольких объектов параллельно.
    static func allocated(_ urls: [URL]) -> [Int64] {
        var sizes = [Int64](repeating: 0, count: urls.count)
        sizes.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in base[i] = allocated(urls[i]) }
        }
        return sizes
    }
}

// MARK: - Диск

struct DiskInfo: Sendable {
    var total: Int64 = 0
    var available: Int64 = 0
    var used: Int64 { max(0, total - available) }

    static func current() -> DiskInfo {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return DiskInfo() }
        return DiskInfo(total: Int64(v.volumeTotalCapacity ?? 0),
                        available: v.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

// MARK: - Формат

enum Fmt {
    /// Байты как в Finder (десятичные единицы, локаль системы).
    static func bytes(_ v: Int64) -> String { v.formatted(.byteCount(style: .file).locale(L10n.locale)) }

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale))
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return String(localized: "неизвестно") }
        return d.formatted(.relative(presentation: .named).locale(L10n.locale))
    }

    static func items(_ n: Int) -> String { String(localized: "\(n) объектов") }
    static func itemsMoved(_ n: Int) -> String { String(localized: "\(n) объектов перенесены") }
    static func files(_ n: Int) -> String { String(localized: "\(n) файлов") }
}

// MARK: - Пути

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    static let library = home.appendingPathComponent("Library", isDirectory: true)
    static let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL

    static func inHome(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    /// ~/Library/Caches → ~/Library/Caches для показа пользователю.
    static func pretty(_ url: URL) -> String {
        let p = url.path
        return p.hasPrefix(home.path + "/") ? "~" + p.dropFirst(home.path.count) : p
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// `inner` лежит строго внутри `outer` (не совпадает с ним).
    static func isStrictlyInside(_ inner: URL, _ outer: URL) -> Bool {
        let i = inner.standardizedFileURL.path, o = outer.standardizedFileURL.path
        return i.hasPrefix(o.hasSuffix("/") ? o : o + "/") && i.count > o.count + 1
    }
}

// MARK: - Полный доступ к диску

enum FullDiskAccess {
    /// ~/Library/Safari есть на любом Mac и закрыт TCC — прочитать его можно только с полным доступом.
    static var granted: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: Paths.library.appendingPathComponent("Safari").path)) != nil
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Команды

enum Shell {
    struct Result: Sendable {
        var ok: Bool
        var output: String
    }

    /// Запускает программу без оболочки (аргументы не интерпретируются).
    static func run(_ tool: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return Result(ok: false, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(ok: p.terminationStatus == 0, output: out)
    }

    /// Команда с правами администратора: macOS сама спросит пароль. `command` — только константы из кода.
    static func runAsAdmin(_ command: String) -> Result {
        let script = "do shell script \"\(command)\" with administrator privileges"
        let r = run("/usr/bin/osascript", ["-e", script])
        if !r.ok, r.output.contains("-128") { return Result(ok: false, output: String(localized: "Отменено")) }
        return r
    }

    /// Очистить Корзину руками Finder — работает и без полного доступа к диску.
    static func finderEmptyTrash() -> Result {
        run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty the trash"])
    }

    /// Перенос в Корзину через Finder — он сам спросит пароль, если объект принадлежит системе.
    static func finderTrash(_ url: URL) -> Result {
        run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)",
            "-e", "end run",
            url.path,
        ])
    }
}

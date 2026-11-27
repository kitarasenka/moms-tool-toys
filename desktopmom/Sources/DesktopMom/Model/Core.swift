import AppKit
import Foundation

// MARK: - Папки

/// Корни, внутри которых DesktopMom вообще что-то делает. В `--selftest` подменяются временной песочницей.
struct Roots: Sendable {
    var home: URL
    var desktop: URL
    var downloads: URL

    static var real: Roots {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return Roots(
            home: home,
            desktop: fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Desktop"),
            downloads: fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Downloads"))
    }

    var pictures: URL { home.appendingPathComponent("Pictures", isDirectory: true) }
    /// Куда по умолчанию раскладываются снимки экрана: ~/Pictures/Снимки экрана/<месяц>/ (имя — на языке приложения).
    var defaultScreenshots: URL {
        Paths.folder(in: pictures, localized: String(localized: "Снимки экрана"),
                     russian: "Снимки экрана") // l10n:skip — имя папки, созданной русской версией
    }
    /// Куда «убирается остальное»: ~/Documents/Разобрать/<тип>/.
    var inbox: URL {
        Paths.folder(in: home.appendingPathComponent("Documents", isDirectory: true), localized: String(localized: "Разобрать"),
                     russian: "Разобрать") // l10n:skip
    }
    var appSupport: URL { home.appendingPathComponent("Library/Application Support/DesktopMom", isDirectory: true) }
}

enum Paths {
    /// Папка с именем на языке приложения. Если её ещё нет, а русская (созданная раньше) уже есть —
    /// продолжаем класть в русскую, чтобы не плодить две папки при смене языка.
    static func folder(in parent: URL, localized: String, russian: String) -> URL {
        let loc = parent.appendingPathComponent(localized, isDirectory: true)
        guard localized != russian, !exists(loc) else { return loc }
        let ru = parent.appendingPathComponent(russian, isDirectory: true)
        return exists(ru) ? ru : loc
    }

    /// Настоящий путь (ссылки и `..` раскрыты физически, через realpath). Ещё не созданный хвост
    /// дописывается как есть; `..`/`.` в нём — nil (такой путь не принимаем).
    static func canonical(_ url: URL) -> [String]? {
        var path = url.path
        var tail: [String] = []
        while true {
            if let r = realpath(path, nil) {
                let base = URL(fileURLWithPath: String(cString: r)).pathComponents
                free(r)
                return base + tail.reversed()
            }
            let last = (path as NSString).lastPathComponent
            if last == ".." || last == "." { return nil }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return nil }
            tail.append(last)
            path = parent
        }
    }

    /// `url` строго внутри `dir` (не равен ей) — по настоящим путям.
    static func isStrictlyInside(_ url: URL, _ dir: URL) -> Bool {
        guard let a = canonical(url), let b = canonical(dir) else { return false }
        return a.count > b.count && Array(a.prefix(b.count)) == b
    }

    /// Объект лежит прямо в `root`, на верхнем уровне. Сам объект не раскрываем: ссылку двигаем как ссылку,
    /// а вот папку, в которой он лежит, — раскрываем (ссылка-папка наружу не пройдёт).
    static func isTopLevel(_ url: URL, in root: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), !name.contains("/") else { return false }
        guard let parent = canonical(url.deletingLastPathComponent()), let r = canonical(root) else { return false }
        return parent == r
    }

    /// Существует ли сам объект (ссылку не раскрываем).
    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    private static let names = ["Desktop": String(localized: "Рабочий стол"), "Downloads": String(localized: "Загрузки"),
                                "Pictures": String(localized: "Изображения"), "Documents": String(localized: "Документы"),
                                "Movies": String(localized: "Фильмы"), "Music": String(localized: "Музыка"),
                                ".Trash": String(localized: "Корзина")]

    /// «Изображения › Снимки экрана › 2026-11 ноябрь» — путь относительно домашней папки, как его показывает Finder.
    static func pretty(_ url: URL, home: URL) -> String {
        let h = home.standardizedFileURL.pathComponents, p = url.standardizedFileURL.pathComponents
        let rel: [String]
        if p.count > h.count, Array(p.prefix(h.count)) == h { rel = Array(p.dropFirst(h.count)) } else { return url.path }
        return rel.enumerated().map { i, c in i == 0 ? (names[c] ?? c) : c }.joined(separator: " › ")
    }
}

// MARK: - Корзина

struct Trasher: Sendable {
    /// Переносит в Корзину, возвращает, где объект оказался.
    var move: @Sendable (URL) throws -> URL?

    static let system = Trasher { url in
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
    }

    /// Для `--selftest`: «Корзина» — обычная папка, настоящая Корзина не засоряется.
    static func folder(_ dir: URL) -> Trasher {
        Trasher { url in
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(String(UUID().uuidString.prefix(8)) + "-" + url.lastPathComponent)
            try fm.moveItem(at: url, to: dest)
            return dest
        }
    }
}

// MARK: - Команды

enum Shell {
    /// Запускает программу без оболочки (аргументы не интерпретируются).
    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (false, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

/// Куда macOS сохраняет новые снимки экрана (`com.apple.screencapture location`; нет значения — Рабочий стол).
enum ScreenshotLocation {
    static func current() -> String? {
        let r = Shell.run("/usr/bin/defaults", ["read", "com.apple.screencapture", "location"])
        let v = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !v.isEmpty ? (v as NSString).expandingTildeInPath : nil
    }

    static func set(_ dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Shell.run("/usr/bin/defaults", ["write", "com.apple.screencapture", "location", "-string", dir.path]).ok
    }

    static func reset() -> Bool {
        Shell.run("/usr/bin/defaults", ["delete", "com.apple.screencapture", "location"])
        return current() == nil
    }
}

// MARK: - Форматирование

enum Fmt {

    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(.dateTime.day().month(.abbreviated).year().locale(L10n.locale))
    }

    static func dateTime(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.wide).hour().minute().locale(L10n.locale))
    }

    static func ago(_ d: Date?, now: Date = .now) -> String {
        guard let d else { return "—" }
        let days = Int(now.timeIntervalSince(d) / 86_400)
        if days < 1 { return String(localized: "сегодня") }
        if days < 2 { return String(localized: "вчера") }
        if days < 31 { return String(localized: "\(days) дней назад") }
        if days < 365 { let m = days / 30; return String(localized: "\(m) месяцев назад") }
        let y = days / 365
        return String(localized: "\(y) лет назад")
    }

    /// «3 файла» — формы числа берутся из Localizable.stringsdict.
    static func files(_ n: Int) -> String { String(localized: "\(n) файлов") }
}

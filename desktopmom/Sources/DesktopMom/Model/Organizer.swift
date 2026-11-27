import Foundation

// MARK: - Перемещение и Корзина

enum SafetyError: LocalizedError {
    case notTopLevel, destinationOutsideHome, destinationInsideSource, missing, occupied, outsideHome

    var errorDescription: String? {
        switch self {
        case .notTopLevel: "лежит не прямо в своей папке — пропущено"
        case .destinationOutsideHome: "папка назначения вне домашней папки — пропущено"
        case .destinationInsideSource: "нельзя переложить папку в саму себя — пропущено"
        case .missing: "файла уже нет на месте"
        case .occupied: "на старом месте уже лежит файл с таким именем"
        case .outsideHome: "путь вне домашней папки — пропущено"
        }
    }
}

struct OpResult: Sendable {
    var done: [(from: URL, to: URL?)] = []
    var failures: [(url: URL, reason: String)] = []
}

enum Organizer {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Fmt.ru
        return c
    }()

    /// «2026-11 ноябрь» — сортируется по порядку и читается по-русски.
    static func monthFolder(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Fmt.ru
        f.calendar = calendar
        f.dateFormat = "yyyy-MM LLLL"
        return f.string(from: date)
    }

    /// «имя.png» → «имя 2.png», «имя 3.png»… — ничего не перезаписываем.
    static func uniqueURL(for name: String, in dir: URL) -> URL {
        let first = dir.appendingPathComponent(name)
        if !Paths.exists(first) { return first }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for i in 2...9_999 {
            let n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let u = dir.appendingPathComponent(n)
            if !Paths.exists(u) { return u }
        }
        return dir.appendingPathComponent("\(base) \(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"))
    }

    /// Проверка перед переносом: источник — верхний уровень `root`, назначение — внутри домашней папки
    /// и не внутри самого источника.
    static func check(source: URL, root: URL, destDir: URL, home: URL) throws {
        guard Paths.isTopLevel(source, in: root) else { throw SafetyError.notTopLevel }
        guard Paths.exists(source) else { throw SafetyError.missing }
        guard Paths.isStrictlyInside(destDir, home) else { throw SafetyError.destinationOutsideHome }
        guard let d = Paths.canonical(destDir), let parent = Paths.canonical(source.deletingLastPathComponent()) else {
            throw SafetyError.notTopLevel
        }
        let src = parent + [source.lastPathComponent]
        if d.count >= src.count && Array(d.prefix(src.count)) == src { throw SafetyError.destinationInsideSource }
        if let real = Paths.canonical(source), d.count >= real.count, Array(d.prefix(real.count)) == real {
            throw SafetyError.destinationInsideSource
        }
    }

    /// Переносит каждый (источник → папка). Только перемещение: если имя занято — «имя 2».
    static func move(_ items: [(source: URL, destDir: URL)], root: URL, home: URL) -> OpResult {
        let fm = FileManager.default
        var r = OpResult()
        for (src, dir) in items {
            do {
                try check(source: src, root: root, destDir: dir, home: home)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = uniqueURL(for: src.lastPathComponent, in: dir)
                try fm.moveItem(at: src, to: dest)  // moveItem не перезаписывает существующее
                r.done.append((src, dest))
            } catch {
                r.failures.append((src, reason(error)))
            }
        }
        return r
    }

    /// В Корзину — только выбранное и только с верхнего уровня `root`.
    static func trash(_ urls: [URL], root: URL, trasher: Trasher = .system) -> OpResult {
        var r = OpResult()
        for u in urls {
            do {
                guard Paths.isTopLevel(u, in: root) else { throw SafetyError.notTopLevel }
                guard Paths.exists(u) else { throw SafetyError.missing }
                r.done.append((u, try trasher.move(u)))
            } catch {
                r.failures.append((u, reason(error)))
            }
        }
        return r
    }

    static func reason(_ e: Error) -> String {
        if let s = e as? SafetyError { return s.errorDescription ?? "\(s)" }
        let ns = e as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError) {
            return "нет доступа"
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteFileExistsError { return "файл с таким именем уже есть" }
        return ns.localizedDescription
    }
}

// MARK: - Журнал

struct LogEntry: Codable, Identifiable, Hashable, Sendable {
    enum Action: String, Codable, Sendable { case moved, trashed }

    var id = UUID()
    var date: Date
    var action: Action
    var from: String
    var to: String?
    var undone = false

    var name: String { (from as NSString).lastPathComponent }
}

/// `~/Library/Application Support/DesktopMom/log.json` (папка 0700, файл 0600). `url == nil` — только в памяти (демо).
@MainActor
final class Journal {
    let url: URL?
    private(set) var entries: [LogEntry] = []
    static let limit = 3_000

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder.iso.decode([LogEntry].self, from: data) {
            entries = list
        }
    }

    func add(_ new: [LogEntry]) {
        guard !new.isEmpty else { return }
        entries.append(contentsOf: new)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        save()
    }

    func markUndone(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].undone = true
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        guard let url else { return }
        Self.write(entries, to: url)
    }

    nonisolated static func write(_ entries: [LogEntry], to url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard let data = try? JSONEncoder.iso.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Можно вернуть: файл всё ещё там, куда его положили, а старое место свободно.
    nonisolated static func canUndo(_ e: LogEntry, home: URL) -> Bool {
        (try? undoCheck(e, home: home)) != nil
    }

    nonisolated private static func undoCheck(_ e: LogEntry, home: URL) throws -> (URL, URL) {
        guard !e.undone, let to = e.to else { throw SafetyError.missing }
        let from = URL(fileURLWithPath: e.from), now = URL(fileURLWithPath: to)
        guard Paths.isStrictlyInside(from, home) else { throw SafetyError.outsideHome }
        guard Paths.exists(now) else { throw SafetyError.missing }
        guard !Paths.exists(from) else { throw SafetyError.occupied }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: from.deletingLastPathComponent().path, isDirectory: &isDir), isDir.boolValue
        else { throw SafetyError.missing }
        return (now, from)
    }

    nonisolated static func undo(_ e: LogEntry, home: URL) throws {
        let (now, from) = try undoCheck(e, home: home)
        try FileManager.default.moveItem(at: now, to: from)
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

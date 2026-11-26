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

    static func allocated(_ urls: [URL]) -> Int64 { urls.reduce(0) { $0 + allocated($1) } }
}

// MARK: - Формат

enum Fmt {
    /// Байты как в Finder (десятичные единицы, локаль системы).
    static func bytes(_ v: Int64) -> String { v.formatted(.byteCount(style: .file)) }

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .standard) }

    static func duration(_ s: TimeInterval) -> String {
        let s = Int(s.rounded())
        if s < 60 { return "\(s) с" }
        if s < 3600 { return "\(s / 60) мин \(s % 60) с" }
        return "\(s / 3600) ч \(s % 3600 / 60) мин"
    }

    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        let w = (m10 == 1 && m100 != 11) ? one : ((2...4).contains(m10) && !(12...14).contains(m100) ? few : many)
        return "\(n.formatted()) \(w)"
    }
}

// MARK: - Пути

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    static let library = home.appendingPathComponent("Library", isDirectory: true)
    static let appSupport = library.appendingPathComponent("Application Support", isDirectory: true)
    static let caches = library.appendingPathComponent("Caches", isDirectory: true)
    static let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL

    /// Своя папка: ~/Library/Application Support/PrivacyMom.
    static let ownData = appSupport.appendingPathComponent("PrivacyMom", isDirectory: true)

    static func pretty(_ url: URL) -> String { pretty(url.path) }

    static func pretty(_ p: String) -> String {
        p.hasPrefix(home.path + "/") ? "~" + p.dropFirst(home.path.count) : p
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
    /// Пользовательская база разрешений открывается только с полным доступом к диску.
    /// Проверяем настоящим открытием файла: без доступа это просто ошибка, без запроса на экране.
    static var granted: Bool {
        if let h = FileHandle(forReadingAtPath: TCCPaths.user.path) { try? h.close(); return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: Paths.library.appendingPathComponent("Safari").path)) != nil
    }

    static func openSettings() { open(pane: "Privacy_AllFiles") }

    /// Раздел «Конфиденциальность и безопасность» в Системных настройках.
    static func open(pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Приложения

struct AppIdentity: Sendable {
    var name: String
    var url: URL?
}

enum AppResolver {
    nonisolated(unsafe) private static var cache: [String: AppIdentity] = [:]
    private static let lock = NSLock()

    /// Имя и путь приложения по bundle id (`client_type` 0) или пути к программе (`client_type` 1).
    static func resolve(_ client: String, isPath: Bool) -> AppIdentity {
        let key = (isPath ? "p:" : "b:") + client
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let r = isPath ? byPath(client) : byBundleID(client)
        cache[key] = r
        return r
    }

    private static func byBundleID(_ id: String) -> AppIdentity {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return AppIdentity(name: displayName(url), url: url)
        }
        return AppIdentity(name: id, url: nil)
    }

    private static func byPath(_ path: String) -> AppIdentity {
        // /Applications/X.app/Contents/MacOS/x → X.app
        if let r = path.range(of: ".app/") {
            let app = URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app")
            if FileManager.default.fileExists(atPath: app.path) { return AppIdentity(name: displayName(app), url: app) }
        }
        let url = URL(fileURLWithPath: path)
        return AppIdentity(name: url.lastPathComponent, url: FileManager.default.fileExists(atPath: path) ? url : nil)
    }

    private static func displayName(_ url: URL) -> String {
        var n = FileManager.default.displayName(atPath: url.path)
        if n.hasSuffix(".app") { n.removeLast(4) }
        return n
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

    /// AppleScript, который запускает `tool` с аргументами через `do shell script`.
    /// Сами аргументы в текст скрипта не попадают: они приходят в `argv` и экранируются `quoted form of`.
    static func doShellScriptSource(argCount: Int, admin: Bool) -> [String] {
        var parts = ["quoted form of (item 1 of argv)"]
        for i in 0..<argCount { parts.append("quoted form of (item \(i + 2) of argv)") }
        let cmd = parts.joined(separator: " & \" \" & ")
        return [
            "-e", "on run argv",
            "-e", "do shell script (\(cmd))" + (admin ? " with administrator privileges" : ""),
            "-e", "end run",
        ]
    }

    /// Запуск через `osascript`: при `admin` macOS сама спросит пароль администратора.
    static func runViaAppleScript(_ tool: String, _ args: [String], admin: Bool) -> Result {
        let r = run("/usr/bin/osascript", doShellScriptSource(argCount: args.count, admin: admin) + [tool] + args)
        if !r.ok, r.output.contains("-128") { return Result(ok: false, output: "Отменено") }
        return r
    }
}

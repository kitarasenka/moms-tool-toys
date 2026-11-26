import AppKit
import Foundation

// MARK: - Каталог браузеров

enum BrowserEngine: Sendable {
    /// Chromium: профили `Default`, `Profile N` внутри папки данных; кэш — в ~/Library/Caches/<cacheDir>/<профиль>.
    case chromium(data: String, cache: String)
    case firefox
    case safari
}

struct BrowserDef: Identifiable, Sendable {
    let id: String
    let name: String
    let bundleID: String
    let engine: BrowserEngine

    static let all: [BrowserDef] = [
        .init(id: "safari", name: "Safari", bundleID: "com.apple.Safari", engine: .safari),
        .init(id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome",
              engine: .chromium(data: "Google/Chrome", cache: "Google/Chrome")),
        .init(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox", engine: .firefox),
        .init(id: "yandex", name: "Яндекс Браузер", bundleID: "ru.yandex.desktop.yandex-browser",
              engine: .chromium(data: "Yandex/YandexBrowser", cache: "Yandex/YandexBrowser")),
        .init(id: "edge", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
              engine: .chromium(data: "Microsoft Edge", cache: "Microsoft Edge")),
        .init(id: "brave", name: "Brave", bundleID: "com.brave.Browser",
              engine: .chromium(data: "BraveSoftware/Brave-Browser", cache: "BraveSoftware/Brave-Browser")),
        .init(id: "arc", name: "Arc", bundleID: "company.thebrowser.Browser",
              engine: .chromium(data: "Arc/User Data", cache: "Arc/User Data")),
        .init(id: "opera", name: "Opera", bundleID: "com.operasoftware.Opera",
              engine: .chromium(data: "com.operasoftware.Opera", cache: "com.operasoftware.Opera")),
    ]

    var isSafari: Bool { if case .safari = engine { true } else { false } }
    var isFirefox: Bool { if case .firefox = engine { true } else { false } }
}

enum BrowserDataKind: String, CaseIterable, Identifiable, Sendable {
    case history, cookies, cache
    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: "История"
        case .cookies: "Cookies"
        case .cache: "Кэш"
        }
    }

    var icon: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .cookies: "birthday.cake"
        case .cache: "internaldrive"
        }
    }

    var actionTitle: String {
        switch self {
        case .history: "Очистить историю"
        case .cookies: "Очистить cookies"
        case .cache: "Очистить кэш"
        }
    }

    /// История и cookies — в Корзину (можно вернуть), кэш удаляется сразу (браузер создаст заново).
    var toTrash: Bool { self != .cache }
}

/// Корни, от которых строятся пути (в самопроверке — временная папка с поддельными профилями).
struct BrowserRoots: Sendable {
    var library: URL
    var appSupport: URL { library.appendingPathComponent("Application Support", isDirectory: true) }
    var caches: URL { library.appendingPathComponent("Caches", isDirectory: true) }

    static let real = BrowserRoots(library: Paths.library)
}

// MARK: - Что именно чистим

struct CleanFile: Identifiable, Sendable, Hashable {
    var url: URL
    var root: URL        // удалять можно только то, что строго внутри корня
    var size: Int64
    var id: String { url.path }
}

struct BrowserTarget: Sendable {
    var kind: BrowserDataKind
    var files: [CleanFile] = []
    var unavailable: String?   // почему нельзя: нет доступа, не поддерживается и т. п.
    var size: Int64 { files.reduce(0) { $0 + $1.size } }
}

struct BrowserReport: Identifiable, Sendable {
    var def: BrowserDef
    var appURL: URL?
    var running: Bool
    var profiles: [String]
    var targets: [BrowserDataKind: BrowserTarget]
    var id: String { def.id }

    func target(_ k: BrowserDataKind) -> BrowserTarget { targets[k] ?? BrowserTarget(kind: k) }
}

enum BrowserScanner {
    /// Файлы, которые никогда не трогаем: пароли, закладки, ключи, автозаполнение, история+закладки Firefox.
    static let protectedNames: Set<String> = [
        "Login Data", "Login Data-journal", "Login Data For Account", "Login Data For Account-journal",
        "Bookmarks", "Bookmarks.bak", "Web Data", "Web Data-journal", "Preferences", "Secure Preferences",
        "Local State", "logins.json", "logins-backup.json", "key4.db", "key3.db", "cert9.db",
        "places.sqlite", "places.sqlite-wal", "places.sqlite-shm", "favicons.sqlite", "formhistory.sqlite",
        "Bookmarks.plist", "Keychain", "Passwords.db",
    ]

    static func installedReports(roots: BrowserRoots = .real, fullDiskAccess: Bool, measure: Bool = true) -> [BrowserReport] {
        BrowserDef.all.compactMap { def in
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: def.bundleID)
            let r = report(def, roots: roots, fullDiskAccess: fullDiskAccess, measure: measure)
            guard app != nil || !r.profiles.isEmpty || def.isSafari else { return nil }
            var out = r
            out.appURL = app
            out.running = isRunning(def)
            return out
        }
    }

    static func isRunning(_ def: BrowserDef) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: def.bundleID).isEmpty
    }

    static func report(_ def: BrowserDef, roots: BrowserRoots, fullDiskAccess: Bool, measure: Bool) -> BrowserReport {
        var targets: [BrowserDataKind: BrowserTarget] = [:]
        for k in BrowserDataKind.allCases {
            targets[k] = target(def, k, roots: roots, fullDiskAccess: fullDiskAccess, measure: measure)
        }
        return BrowserReport(def: def, appURL: nil, running: false,
                             profiles: profiles(def, roots: roots, fullDiskAccess: fullDiskAccess), targets: targets)
    }

    // MARK: Профили

    static func profiles(_ def: BrowserDef, roots: BrowserRoots, fullDiskAccess: Bool) -> [String] {
        switch def.engine {
        case .chromium(let data, _):
            return chromiumProfiles(roots.appSupport.appendingPathComponent(data, isDirectory: true))
        case .firefox:
            return firefoxProfiles(roots).map(\.lastPathComponent)
        case .safari:
            return fullDiskAccess ? ["Safari"] : []
        }
    }

    /// `Default`, `Profile 1`… (служебные `System Profile`, `Guest Profile` пропускаем). Старая Opera хранит
    /// всё прямо в корне — тогда профиль один, с пустым именем.
    static func chromiumProfiles(_ dataDir: URL) -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dataDir.path)) ?? []
        var out = names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .filter { var d: ObjCBool = false; return fm.fileExists(atPath: dataDir.appendingPathComponent($0).path, isDirectory: &d) && d.boolValue }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if out.isEmpty, fm.fileExists(atPath: dataDir.appendingPathComponent("History").path) { out = [""] }
        return out
    }

    static func firefoxProfiles(_ roots: BrowserRoots) -> [URL] {
        let dir = roots.appSupport.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { dir.appendingPathComponent($0, isDirectory: true) }
    }

    // MARK: Цели

    static func target(_ def: BrowserDef, _ kind: BrowserDataKind, roots: BrowserRoots,
                       fullDiskAccess: Bool, measure: Bool) -> BrowserTarget {
        var t = BrowserTarget(kind: kind)
        var candidates: [(URL, URL)] = []   // (файл, корень)

        switch def.engine {
        case .chromium(let data, let cache):
            let dataDir = roots.appSupport.appendingPathComponent(data, isDirectory: true)
            let cacheDir = roots.caches.appendingPathComponent(cache, isDirectory: true)
            for p in chromiumProfiles(dataDir) {
                let prof = p.isEmpty ? dataDir : dataDir.appendingPathComponent(p, isDirectory: true)
                switch kind {
                case .history:
                    candidates += ["History", "History-journal"].map { (prof.appendingPathComponent($0), dataDir) }
                case .cookies:
                    candidates += ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]
                        .map { (prof.appendingPathComponent($0), dataDir) }
                case .cache:
                    let c = p.isEmpty ? cacheDir : cacheDir.appendingPathComponent(p, isDirectory: true)
                    candidates += children(c).map { ($0, cacheDir) }
                }
            }

        case .firefox:
            switch kind {
            case .history:
                t.unavailable = "История Firefox лежит в одном файле с закладками (places.sqlite) — её очищают в самом Firefox: Настройки → Приватность → «Удалить историю»."
            case .cookies:
                let base = roots.appSupport.appendingPathComponent("Firefox/Profiles", isDirectory: true)
                for p in firefoxProfiles(roots) {
                    candidates += ["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"]
                        .map { (p.appendingPathComponent($0), base) }
                }
            case .cache:
                let base = roots.caches.appendingPathComponent("Firefox/Profiles", isDirectory: true)
                for p in firefoxProfiles(roots) {
                    candidates += children(base.appendingPathComponent(p.lastPathComponent).appendingPathComponent("cache2"))
                        .map { ($0, base) }
                }
            }

        case .safari:
            // Всё, что связано с Safari, закрыто системой: без полного доступа даже не заглядываем
            // (иначе macOS спросит про «данные других приложений»).
            guard fullDiskAccess else {
                t.unavailable = "нужен доступ"
                return t
            }
            let container = roots.library.appendingPathComponent("Containers/com.apple.Safari/Data/Library", isDirectory: true)
            switch kind {
            case .history:
                let dir = roots.library.appendingPathComponent("Safari", isDirectory: true)
                candidates += ["History.db", "History.db-shm", "History.db-wal", "History.db-lock"]
                    .map { (dir.appendingPathComponent($0), dir) }
            case .cookies:
                for dir in [container.appendingPathComponent("Cookies", isDirectory: true),
                            roots.library.appendingPathComponent("Cookies", isDirectory: true)] {
                    candidates.append((dir.appendingPathComponent("Cookies.binarycookies"), dir))
                }
            case .cache:
                for dir in [roots.caches.appendingPathComponent("com.apple.Safari", isDirectory: true),
                            container.appendingPathComponent("Caches/com.apple.Safari", isDirectory: true)] {
                    candidates += children(dir).map { ($0, dir) }
                }
            }
        }

        let fm = FileManager.default
        for (url, root) in candidates where fm.fileExists(atPath: url.path) && isSafe(url, root: root) {
            t.files.append(CleanFile(url: url, root: root, size: measure ? DiskSize.allocated(url) : 0))
        }
        return t
    }

    private static func children(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 != ".DS_Store" }
            .map { dir.appendingPathComponent($0) }
    }

    /// Удалять можно только объект строго внутри своего корня и не из списка защищённых.
    static func isSafe(_ url: URL, root: URL) -> Bool {
        guard Paths.isStrictlyInside(url, root), !protectedNames.contains(url.lastPathComponent) else { return false }
        // Корень не может быть домашней папкой или ~/Library.
        let r = root.standardizedFileURL.path
        return r != Paths.home.path && r != Paths.library.path && r.count > 1
    }

    // MARK: Очистка

    struct CleanResult: Sendable {
        var removed = 0
        var freed: Int64 = 0
        var failures: [String] = []
    }

    /// Убирает файлы цели. История и cookies — в Корзину, кэш — сразу.
    /// `checkRunning` и `trash` подменяются только в самопроверке.
    static func clean(_ def: BrowserDef, _ target: BrowserTarget, checkRunning: Bool = true,
                      trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> CleanResult {
        var r = CleanResult()
        if checkRunning, isRunning(def) {
            r.failures.append("\(def.name) запущен — закройте его и попробуйте снова.")
            return r
        }
        let fm = FileManager.default
        for f in target.files {
            guard isSafe(f.url, root: f.root) else { r.failures.append("пропущено (вне папки браузера): \(Paths.pretty(f.url))"); continue }
            guard fm.fileExists(atPath: f.url.path) else { continue }
            do {
                if target.kind.toTrash { try trash(f.url) } else { try fm.removeItem(at: f.url) }
                r.removed += 1
                r.freed += f.size
            } catch {
                r.failures.append("\(Paths.pretty(f.url)): \(error.localizedDescription)")
            }
        }
        return r
    }
}

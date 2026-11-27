import AppKit
import Foundation

// Деинсталлятор: приложения из /Applications и ~/Applications и их следы в ~/Library.
// Всё удаляется в Корзину — ошибку можно исправить, вернув файлы.

struct AppInfo: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let lastUsed: Date?
    var id: String { url.path }
}

struct Leftover: Identifiable, Hashable, Sendable {
    let url: URL
    let kind: String
    let size: Int64  // -1 — неизвестен (нет полного доступа к диску)
    var id: String { url.path }
}

enum AppScanner {
    static let folders = [URL(fileURLWithPath: "/Applications"), Paths.home.appendingPathComponent("Applications")]

    static func installedApps() -> [AppInfo] {
        let fm = FileManager.default
        var bundles: [URL] = []
        for dir in folders {
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                if url.pathExtension == "app" {
                    bundles.append(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // Одна вложенная папка (например, /Applications/Utilities или папки комплектов)
                    for sub in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                    where sub.pathExtension == "app" { bundles.append(sub) }
                }
            }
        }
        var seen = Set<String>()
        var apps: [AppInfo] = []
        for url in bundles {
            guard let b = Bundle(url: url), let bid = b.bundleIdentifier else { continue }
            // Системные приложения Apple трогать не даём.
            if bid.hasPrefix("com.apple.") { continue }
            if bid == Bundle.main.bundleIdentifier { continue }
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
            var name = fm.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            let version = b.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            apps.append(AppInfo(url: url, name: name, bundleID: bid, version: version, lastUsed: lastUsed(url)))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Следы приложения в ~/Library: точные совпадения по bundle id и по имени.
    static func leftovers(for app: AppInfo, measure: Bool = true) -> [Leftover] {
        let fm = FileManager.default
        let lib = Paths.library
        let bid = app.bundleID
        var names = Set([app.name])
        if let b = Bundle(url: app.url), let n = b.infoDictionary?["CFBundleName"] as? String, !n.isEmpty { names.insert(n) }

        var found: [(URL, String)] = []
        func check(_ rel: String, _ kind: String) {
            let url = lib.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) { found.append((url, kind)) }
        }
        check("Application Support/\(bid)", String(localized: "Данные приложения"))
        check("Caches/\(bid)", String(localized: "Кэш"))
        check("Containers/\(bid)", String(localized: "Контейнер (данные и настройки)"))
        check("Preferences/\(bid).plist", String(localized: "Настройки"))
        check("Saved Application State/\(bid).savedState", String(localized: "Состояние окон"))
        check("HTTPStorages/\(bid)", String(localized: "Сетевые данные"))
        check("HTTPStorages/\(bid).binarycookies", "Cookies")
        check("Cookies/\(bid).binarycookies", "Cookies")
        check("WebKit/\(bid)", String(localized: "Данные веб-страниц"))
        check("Logs/\(bid)", String(localized: "Журналы"))
        check("Application Scripts/\(bid)", String(localized: "Скрипты"))
        for n in names where !n.isEmpty {
            check("Application Support/\(n)", String(localized: "Данные приложения"))
            check("Caches/\(n)", String(localized: "Кэш"))
            check("Logs/\(n)", String(localized: "Журналы"))
        }
        // Файлы с bundle id в начале имени: настройки ByHost, агенты автозапуска, помощники.
        let prefixDirs: [(String, String)] = [
            ("Preferences/ByHost", String(localized: "Настройки")), ("LaunchAgents", String(localized: "Агент автозапуска")),
            ("Containers", String(localized: "Контейнер помощника")), ("Application Scripts", String(localized: "Скрипты")),
        ]
        for (rel, kind) in prefixDirs {
            let dir = lib.appendingPathComponent(rel)
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let n = url.lastPathComponent
                if n.hasPrefix(bid + ".") { found.append((url, kind)) }
            }
        }
        // Group Containers: «TEAMID.bundle.id» или «group.bundle.id».
        let groups = lib.appendingPathComponent("Group Containers")
        for url in (try? fm.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? [] {
            let n = url.lastPathComponent
            if n.hasSuffix("." + bid) || n == "group." + bid { found.append((url, String(localized: "Общий контейнер"))) }
        }

        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.0.standardizedFileURL.path).inserted }
            .filter { Paths.isStrictlyInside($0.0, lib) }
        // Контейнеры других приложений без полного доступа к диску не читаем: macOS спросит разрешение.
        // Размер таких следов неизвестен (-1), удалить их всё равно можно.
        let fda = FullDiskAccess.granted
        let guarded = [lib.appendingPathComponent("Containers"), lib.appendingPathComponent("Group Containers")]
        let sizes: [Int64] = unique.map { entry in
            guard measure else { return 0 }
            if !fda, guarded.contains(where: { Paths.isStrictlyInside(entry.0, $0) }) { return -1 }
            return DiskSize.allocated(entry.0)
        }
        return zip(unique, sizes).map { Leftover(url: $0.0.0, kind: $0.0.1, size: $0.1) }
            .sorted { $0.size > $1.size }
    }

    struct UninstallReport: Sendable {
        var freed: Int64 = 0
        var failures: [String] = []
    }

    /// Переносит приложение и выбранные следы в Корзину. Приложение должно быть уже закрыто.
    static func uninstall(_ app: AppInfo, appSize: Int64, leftovers: [Leftover]) -> UninstallReport {
        var report = UninstallReport()
        let fm = FileManager.default
        do {
            try fm.trashItem(at: app.url, resultingItemURL: nil)
            report.freed += appSize
        } catch {
            // Приложение принадлежит системе (часто из App Store) — Finder спросит пароль.
            let r = Shell.finderTrash(app.url)
            if r.ok || !fm.fileExists(atPath: app.url.path) {
                report.freed += appSize
            } else {
                report.failures.append("\(app.name).app: \(r.output.isEmpty ? Cleaner.reason(error) : r.output)")
                return report  // без приложения следы не трогаем
            }
        }
        for l in leftovers where Paths.isStrictlyInside(l.url, Paths.library) {
            do {
                try fm.trashItem(at: l.url, resultingItemURL: nil)
                report.freed += max(0, l.size)
            } catch {
                report.failures.append("\(Paths.pretty(l.url)): \(Cleaner.reason(error))")
            }
        }
        return report
    }
}

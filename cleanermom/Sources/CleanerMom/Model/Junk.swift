import AppKit
import Foundation

// Каталог мусора: что ищем, где и как удаляем.
// Правило безопасности: каждый найденный объект знает свою папку-корень (`root`), а корень лежит
// в домашней папке или во временной папке пользователя. Cleaner удаляет только то, что строго внутри корня.

enum JunkGroup: String, CaseIterable, Identifiable, Sendable {
    case system, browsers, developer, files

    var title: String {
        switch self {
        case .system: String(localized: "Система")
        case .browsers: String(localized: "Браузеры")
        case .developer: String(localized: "Разработка")
        case .files: String(localized: "Файлы и загрузки")
        }
    }
    var id: String { rawValue }
}

enum RemovalMode: Sendable {
    case delete  // сразу (кэши, журналы — приложения создадут их заново)
    case trash   // в Корзину (файлы пользователя — можно вернуть)
}

struct JunkItem: Identifiable, Hashable, Sendable {
    let url: URL
    let root: URL
    let size: Int64
    let title: String
    let subtitle: String?
    /// Почему объект не отмечен по умолчанию (например, приложение запущено).
    let note: String?
    var id: String { url.path }
    var preselected: Bool { note == nil }
}

struct ScanContext: Sendable {
    let runningIDs: Set<String>    // bundle id в нижнем регистре
    let runningNames: Set<String>  // имена приложений в нижнем регистре

    @MainActor static func current() -> ScanContext {
        let apps = NSWorkspace.shared.runningApplications
        return ScanContext(runningIDs: Set(apps.compactMap { $0.bundleIdentifier?.lowercased() }),
                           runningNames: Set(apps.compactMap { $0.localizedName?.lowercased() }))
    }

    func isRunning(_ idOrName: String) -> Bool {
        let k = idOrName.lowercased()
        return runningIDs.contains(k) || runningNames.contains(k)
    }
}

/// Что нашёл сборщик категории до подсчёта размеров.
struct Collected {
    struct Candidate {
        var url: URL
        var root: URL
        var title: String
        var subtitle: String? = nil
        var note: String? = nil
    }

    var candidates: [Candidate] = []
    var denied: [URL] = []

    /// Содержимое папки; закрытую системой папку запоминает (нужен полный доступ к диску).
    mutating func children(of dir: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
            return []
        } catch {
            if FileManager.default.fileExists(atPath: dir.path) { denied.append(dir) }
            return []
        }
    }

    mutating func add(_ url: URL, root: URL, title: String? = nil, subtitle: String? = nil, note: String? = nil) {
        candidates.append(Candidate(url: url, root: root, title: title ?? url.lastPathComponent,
                                    subtitle: subtitle, note: note))
    }
}

struct JunkCategory: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let group: JunkGroup
    let defaultOn: Bool
    let mode: RemovalMode
    let collect: @Sendable (ScanContext, inout Collected) -> Void
}

struct CategoryResult: Sendable {
    var items: [JunkItem] = []
    var denied: [URL] = []
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

// MARK: - Каталог

enum Catalog {
    static let caches = Paths.library.appendingPathComponent("Caches", isDirectory: true)

    /// Кэши браузеров: папка в ~/Library/Caches, bundle id для проверки «запущен ли», имя.
    static let browsers: [(dir: String, bundleID: String, name: String)] = [
        ("com.apple.Safari", "com.apple.Safari", "Safari"),
        ("Google/Chrome", "com.google.Chrome", "Google Chrome"),
        ("Firefox", "org.mozilla.firefox", "Firefox"),
        ("Yandex", "ru.yandex.desktop.yandex-browser", String(localized: "Яндекс Браузер")),
        ("BraveSoftware", "com.brave.Browser", "Brave"),
        ("Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge"),
        ("company.thebrowser.Browser", "company.thebrowser.Browser", "Arc"),
        ("com.operasoftware.Opera", "com.operasoftware.Opera", "Opera"),
        ("com.vivaldi.Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi"),
    ]

    /// Кэши инструментов разработки (путь от домашней папки). Всё скачивается заново при следующей сборке.
    static let devCaches: [(path: String, name: String)] = [
        ("Library/Caches/Homebrew", "Homebrew"),
        (".npm/_cacache", "npm"),
        ("Library/Caches/Yarn", "Yarn"),
        ("Library/Caches/pip", "pip"),
        ("Library/Caches/pypoetry", "Poetry"),
        ("Library/Caches/CocoaPods", "CocoaPods"),
        ("Library/Caches/org.swift.swiftpm", "Swift Package Manager"),
        ("Library/Caches/go-build", "Go"),
        ("Library/Caches/ms-playwright", String(localized: "Playwright (браузеры для тестов)")),
        ("Library/Caches/node-gyp", "node-gyp"),
        ("Library/Caches/deno", "Deno"),
        ("Library/Caches/typescript", "TypeScript"),
        (".gradle/caches", "Gradle"),
        (".cargo/registry/cache", "Cargo"),
    ]

    /// Кэши, которые не трогаем: iCloud, связка ключей, «Локатор», фоновые загрузки и т. п.
    static let protectedCaches: Set<String> = [
        "cloudkit", "com.apple.bird", "com.apple.akd", "com.apple.nsurlsessiond", "com.apple.containermanagerd",
        "familycircle", "com.apple.homekit", "com.apple.homed", "com.apple.icloudhelper", "com.apple.ap.adprivacyd",
        "com.apple.findmy.fmipcore", "com.apple.icloud.fmfd", "com.apple.mobileassetd", "com.apple.amsengagementd",
        "com.apple.passd", "com.apple.appstoreagent", "com.apple.commerce", "com.apple.storeuid",
    ]

    /// Папки ~/Library/Caches, которые разобраны другими категориями.
    static let handledElsewhere: Set<String> = {
        var s = Set(browsers.map { String($0.dir.split(separator: "/")[0]).lowercased() })
        for d in devCaches where d.path.hasPrefix("Library/Caches/") {
            s.insert(String(d.path.dropFirst("Library/Caches/".count)).lowercased())
        }
        return s
    }()

    static let runningNote = String(localized: "Приложение запущено — закройте его, чтобы почистить")

    static let all: [JunkCategory] = [
        JunkCategory(
            id: "caches", title: String(localized: "Кэши приложений"),
            detail: String(localized: "Временные данные программ. Приложения создадут их заново — первый запуск может быть чуть медленнее."),
            icon: "shippingbox", group: .system, defaultOn: true, mode: .delete
        ) { ctx, c in
            for url in c.children(of: caches) {
                let name = url.lastPathComponent
                let key = name.lowercased()
                if protectedCaches.contains(key) || handledElsewhere.contains(key) || key == ".ds_store" { continue }
                if key == (Bundle.main.bundleIdentifier ?? "").lowercased() { continue }
                c.add(url, root: caches, title: AppNames.name(forCacheFolder: name),
                      note: ctx.isRunning(name) ? runningNote : nil)
            }
        },
        JunkCategory(
            id: "logs", title: String(localized: "Журналы и отчёты о сбоях"),
            detail: String(localized: "Журналы программ и отчёты о сбоях из ~/Library/Logs. Нужны только для поиска ошибок."),
            icon: "doc.text.magnifyingglass", group: .system, defaultOn: true, mode: .delete
        ) { ctx, c in
            let logs = Paths.library.appendingPathComponent("Logs", isDirectory: true)
            for url in c.children(of: logs) where url.lastPathComponent != ".DS_Store" {
                let name = url.lastPathComponent
                c.add(url, root: logs, title: name == "DiagnosticReports" ? String(localized: "Отчёты о сбоях") : name,
                      note: ctx.isRunning(name) ? runningNote : nil)
            }
        },
        JunkCategory(
            id: "temp", title: String(localized: "Временные файлы"),
            detail: String(localized: "Файлы из временной папки пользователя, которые не менялись больше недели."),
            icon: "clock.arrow.circlepath", group: .system, defaultOn: true, mode: .delete
        ) { _, c in
            let weekAgo = Date().addingTimeInterval(-7 * 86_400)
            for url in c.children(of: Paths.tmp) {
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let mod, mod < weekAgo else { continue }
                c.add(url, root: Paths.tmp, subtitle: String(localized: "изменён \(Fmt.date(mod))"))
            }
        },
        JunkCategory(
            id: "trash", title: String(localized: "Корзина"),
            detail: String(localized: "Всё, что лежит в Корзине. Очистка удаляет файлы окончательно."),
            icon: "trash", group: .system, defaultOn: true, mode: .delete
        ) { _, c in
            let trash = Paths.home.appendingPathComponent(".Trash", isDirectory: true)
            for url in c.children(of: trash) where url.lastPathComponent != ".DS_Store" {
                c.add(url, root: trash)
            }
        },
        JunkCategory(
            id: "browsers", title: String(localized: "Кэш браузеров"),
            detail: String(localized: "Сохранённые копии страниц и картинок. История, пароли и вход на сайты не затрагиваются."),
            icon: "globe", group: .browsers, defaultOn: true, mode: .delete
        ) { ctx, c in
            for b in browsers {
                let url = caches.appendingPathComponent(b.dir, isDirectory: true)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                c.add(url, root: url.deletingLastPathComponent(), title: b.name,
                      note: ctx.isRunning(b.bundleID) ? String(localized: "Браузер открыт — закройте его, чтобы почистить") : nil)
            }
        },
        JunkCategory(
            id: "xcode", title: "Xcode",
            detail: String(localized: "Промежуточные файлы сборки (DerivedData), символы для подключавшихся устройств и кэш симуляторов."),
            icon: "hammer", group: .developer, defaultOn: true, mode: .delete
        ) { ctx, c in
            let dev = Paths.library.appendingPathComponent("Developer", isDirectory: true)
            let xcodeRunning = ctx.isRunning("com.apple.dt.Xcode")
            let derived = dev.appendingPathComponent("Xcode/DerivedData", isDirectory: true)
            for url in c.children(of: derived) where url.lastPathComponent != ".DS_Store" {
                let name = url.lastPathComponent
                let project = name.split(separator: "-").dropLast().joined(separator: "-")
                c.add(url, root: derived, title: String(localized: "Сборка: \(project.isEmpty ? name : project)"),
                      note: xcodeRunning ? String(localized: "Xcode запущен — закройте его, чтобы почистить") : nil)
            }
            for os in ["iOS", "watchOS", "tvOS", "visionOS"] {
                let dir = dev.appendingPathComponent("Xcode/\(os) DeviceSupport", isDirectory: true)
                for url in c.children(of: dir) where url.lastPathComponent != ".DS_Store" {
                    c.add(url, root: dir, title: String(localized: "Символы \(os) \(url.lastPathComponent)"))
                }
            }
            let sim = dev.appendingPathComponent("CoreSimulator/Caches", isDirectory: true)
            for url in c.children(of: sim) where url.lastPathComponent != ".DS_Store" {
                c.add(url, root: sim, title: String(localized: "Кэш симуляторов: \(url.lastPathComponent)"))
            }
        },
        JunkCategory(
            id: "devcaches", title: String(localized: "Кэши пакетных менеджеров"),
            detail: String(localized: "Скачанные пакеты npm, Homebrew, pip, Gradle и других. Скачаются заново при следующей установке."),
            icon: "shippingbox.circle", group: .developer, defaultOn: false, mode: .delete
        ) { _, c in
            for d in devCaches {
                let url = Paths.inHome(d.path)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                c.add(url, root: url.deletingLastPathComponent(), title: d.name)
            }
        },
        JunkCategory(
            id: "mail", title: String(localized: "Вложения Почты"),
            detail: String(localized: "Копии вложений, которые вы открывали в Почте. Сами письма и вложения в них остаются."),
            icon: "paperclip", group: .files, defaultOn: true, mode: .delete
        ) { _, c in
            let dir = Paths.inHome("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
            // Без полного доступа к диску не стучимся в чужой контейнер — иначе macOS спросит разрешение.
            guard FullDiskAccess.granted else { c.denied.append(dir); return }
            for url in c.children(of: dir) where url.lastPathComponent != ".DS_Store" {
                c.add(url, root: dir)
            }
        },
        JunkCategory(
            id: "ipsw", title: String(localized: "Обновления iPhone и iPad"),
            detail: String(localized: "Скачанные файлы прошивок. Они уже установлены или устарели."),
            icon: "iphone.and.arrow.forward", group: .files, defaultOn: true, mode: .delete
        ) { _, c in
            for kind in ["iPhone", "iPad", "iPod"] {
                let dir = Paths.inHome("Library/iTunes/\(kind) Software Updates")
                for url in c.children(of: dir) where url.pathExtension.lowercased() == "ipsw" {
                    c.add(url, root: dir)
                }
            }
        },
        JunkCategory(
            id: "installers", title: String(localized: "Установщики в Загрузках"),
            detail: String(localized: "Образы .dmg и пакеты .pkg из папки «Загрузки». Попадут в Корзину — их можно вернуть."),
            icon: "arrow.down.app", group: .files, defaultOn: false, mode: .trash
        ) { _, c in
            let dir = Paths.inHome("Downloads")
            let exts: Set<String> = ["dmg", "pkg", "mpkg", "xip"]
            for url in c.children(of: dir) where exts.contains(url.pathExtension.lowercased()) {
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                c.add(url, root: dir, subtitle: String(localized: "скачан \(Fmt.date(mod))"))
            }
        },
        JunkCategory(
            id: "backups", title: String(localized: "Резервные копии iPhone и iPad"),
            detail: String(localized: "Локальные копии устройств из Finder. Попадут в Корзину — их можно вернуть. Проверьте, что копия есть в iCloud."),
            icon: "externaldrive.badge.timemachine", group: .files, defaultOn: false, mode: .trash
        ) { _, c in
            let dir = Paths.inHome("Library/Application Support/MobileSync/Backup")
            for url in c.children(of: dir) where url.lastPathComponent != ".DS_Store" {
                let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
                let device = info?["Device Name"] as? String ?? url.lastPathComponent
                let date = info?["Last Backup Date"] as? Date
                c.add(url, root: dir, title: device, subtitle: String(localized: "копия от \(Fmt.date(date))"))
            }
        },
    ]
}

// MARK: - Имена приложений по папкам кэша

enum AppNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    /// «com.google.Chrome» → «Google Chrome», если такое приложение установлено; иначе имя папки.
    static func name(forCacheFolder folder: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let n = cache[folder] { return n }
        var name = folder
        if folder.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: folder) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        }
        cache[folder] = name
        return name
    }
}

// MARK: - Сканирование

enum JunkScanner {
    static func scan(_ categories: [JunkCategory], context: ScanContext) async -> [String: CategoryResult] {
        await withTaskGroup(of: (String, CategoryResult).self) { group in
            for cat in categories {
                group.addTask { (cat.id, scan(cat, context: context)) }
            }
            var out: [String: CategoryResult] = [:]
            for await (id, r) in group { out[id] = r }
            return out
        }
    }

    static func scan(_ cat: JunkCategory, context: ScanContext) -> CategoryResult {
        var c = Collected()
        cat.collect(context, &c)
        let sizes = DiskSize.allocated(c.candidates.map(\.url))
        var items: [JunkItem] = []
        for (cand, size) in zip(c.candidates, sizes) where size > 0 {
            items.append(JunkItem(url: cand.url, root: cand.root, size: size, title: cand.title,
                                  subtitle: cand.subtitle, note: cand.note))
        }
        items.sort { $0.size > $1.size }
        return CategoryResult(items: items, denied: c.denied)
    }
}

// MARK: - Удаление

struct CleanReport: Sendable {
    struct Failure: Sendable, Identifiable {
        let path: String
        let reason: String
        var id: String { path }
    }

    var freed: Int64 = 0
    var removed: [String] = []
    var trashed: Int = 0
    var failures: [Failure] = []
}

enum Cleaner {
    /// Корни, внутри которых вообще разрешено удалять.
    static let allowedRoots: [URL] = [Paths.home, Paths.tmp]

    static func isSafe(_ item: JunkItem) -> Bool {
        Paths.isStrictlyInside(item.url, item.root)
            && allowedRoots.contains { Paths.isStrictlyInside(item.root, $0) || item.root.standardizedFileURL == $0 }
            && item.root.standardizedFileURL != Paths.home  // не чистим саму домашнюю папку
    }

    static func remove(_ batch: [(item: JunkItem, mode: RemovalMode)],
                       progress: @Sendable (Int) -> Void = { _ in }) -> CleanReport {
        var report = CleanReport()
        let fm = FileManager.default
        for (i, entry) in batch.enumerated() {
            let item = entry.item
            defer { progress(i + 1) }
            guard isSafe(item) else {
                report.failures.append(.init(path: item.url.path, reason: String(localized: "вне разрешённой папки — пропущено")))
                continue
            }
            do {
                switch entry.mode {
                case .delete: try fm.removeItem(at: item.url)
                case .trash:
                    try fm.trashItem(at: item.url, resultingItemURL: nil)
                    report.trashed += 1
                }
                report.freed += item.size
                report.removed.append(item.id)
            } catch {
                // Часть файлов могла удалиться — фиксируем, что осталось.
                if entry.mode == .delete, !fm.fileExists(atPath: item.url.path) {
                    report.freed += item.size
                    report.removed.append(item.id)
                } else {
                    report.failures.append(.init(path: item.url.path, reason: reason(error)))
                }
            }
        }
        return report
    }

    static func reason(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError {
            return String(localized: "нет доступа")
        }
        if let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError), posix.domain == NSPOSIXErrorDomain,
           posix.code == Int(EPERM) || posix.code == Int(EACCES) {
            return String(localized: "нет доступа")
        }
        return ns.localizedDescription
    }
}

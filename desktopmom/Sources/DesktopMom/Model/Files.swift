import CoreServices
import Foundation
import UniformTypeIdentifiers

// MARK: - Группы

enum DeskGroup: String, CaseIterable, Identifiable, Codable, Sendable {
    case screenshots, documents, images, media, installers, archives, folders, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshots: String(localized: "Снимки и записи экрана")
        case .documents: String(localized: "Документы")
        case .images: String(localized: "Картинки и фото")
        case .media: String(localized: "Видео и музыка")
        case .installers: String(localized: "Установщики и программы")
        case .archives: String(localized: "Архивы")
        case .folders: String(localized: "Папки")
        case .other: String(localized: "Прочее")
        }
    }

    /// Имя подпапки в «Документы › Разобрать» на языке приложения.
    var folderName: String {
        switch self {
        case .screenshots: String(localized: "Снимки экрана")
        case .documents: String(localized: "Документы")
        case .images: String(localized: "Картинки")
        case .media: String(localized: "Видео и музыка")
        case .installers: String(localized: "Установщики")
        case .archives: String(localized: "Архивы")
        case .folders: String(localized: "Папки")
        case .other: String(localized: "Прочее")
        }
    }

    /// То же имя по-русски — так папку называла русская версия; если она уже есть, кладём в неё.
    var russianFolderName: String {
        switch self {
        case .screenshots: "Снимки экрана" // l10n:skip
        case .documents: "Документы" // l10n:skip
        case .images: "Картинки" // l10n:skip
        case .media: "Видео и музыка" // l10n:skip
        case .installers: "Установщики" // l10n:skip
        case .archives: "Архивы" // l10n:skip
        case .folders: "Папки" // l10n:skip
        case .other: "Прочее" // l10n:skip
        }
    }

    var icon: String {
        switch self {
        case .screenshots: "camera.viewfinder"
        case .documents: "doc.text"
        case .images: "photo"
        case .media: "film"
        case .installers: "shippingbox"
        case .archives: "doc.zipper"
        case .folders: "folder"
        case .other: "questionmark.square.dashed"
        }
    }
}

// MARK: - Файл

struct Entry: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    var group: DeskGroup
    var size: Int64
    var isFolder = false          // обычная папка (пакет вроде .app — не папка, а один объект)
    var isSymlink = false
    var created: Date?
    var modified: Date?
    var lastUsed: Date?           // kMDItemLastUsedDate — когда открывали
    var added: Date?              // когда попал в эту папку (для Загрузок — когда скачан)
    /// Для установщиков в Загрузках: похожее приложение уже есть в «Программах» (догадка по имени).
    var installedMatch: String?

    var name: String { url.lastPathComponent }

    /// Последнее, что с файлом происходило: изменили, открыли или скачали.
    var lastTouched: Date? { [modified, lastUsed, added].compactMap { $0 }.max() ?? created }

    /// Дата для папки месяца — когда снимок сделан.
    var shotDate: Date { created ?? modified ?? .now }

    func isOld(days: Int, now: Date = .now) -> Bool {
        guard let t = lastTouched else { return false }
        return now.timeIntervalSince(t) > Double(days) * 86_400
    }

    var isInstaller: Bool {
        Classifier.installerExtensions.contains(url.pathExtension.lowercased()) || url.pathExtension.lowercased() == "app"
    }

    static let largeSize: Int64 = 100 * 1_000_000
    var isLarge: Bool { size >= Self.largeSize }
}

// MARK: - Распознавание

enum Classifier {
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg"]
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "sit", "sitx"]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers",
                                                  "key", "rtf", "rtfd", "txt", "odt", "ods", "odp", "csv", "md", "epub",
                                                  "fb2", "djvu", "html", "htm", "webloc"]
    /// Как macOS называет снимки и записи экрана на разных языках (в нижнем регистре) — это данные, не перевод.
    static let screenshotPrefixes = [
        "снимок экрана", "запись экрана",                                  // l10n:skip — ru
        "screenshot", "screen shot", "screen recording", "cleanshot",      // en (+ CleanShot X)
        "bildschirmfoto", "bildschirmaufnahme",                           // de
        "capture d’écran", "capture d'écran", "enregistrement de l’écran", "enregistrement de l'écran",  // fr
        "截屏", "屏幕快照", "屏幕录制",                                         // zh-Hans
        "لقطة شاشة", "تسجيل الشاشة",                                       // ar
    ]

    /// По имени: «Снимок экрана 2026-11-02 в 10.11.12.png», «Screen Recording … .mov», «Bildschirmfoto …» —
    /// только для картинок и видео, чтобы «Screenshot ideas.docx» не уехал в снимки.
    static func looksLikeScreenshot(name: String) -> Bool {
        let lower = name.lowercased()
        guard screenshotPrefixes.contains(where: { lower.hasPrefix($0) }) else { return false }
        guard let t = UTType(filenameExtension: (name as NSString).pathExtension) else { return false }
        return t.conforms(to: .image) || t.conforms(to: .movie)
    }

    static let screenCaptureAttr = "com.apple.metadata:kMDItemIsScreenCapture"

    /// Метка, которую macOS ставит снимкам экрана (расширенный атрибут, а если его нет — Spotlight).
    static func isScreenCapture(_ url: URL, spotlight: Bool = true) -> Bool {
        let path = url.path
        let len = getxattr(path, screenCaptureAttr, nil, 0, 0, XATTR_NOFOLLOW)
        if len > 0 {
            var buf = [UInt8](repeating: 0, count: len)
            if getxattr(path, screenCaptureAttr, &buf, len, 0, XATTR_NOFOLLOW) == len,
               let v = try? PropertyListSerialization.propertyList(from: Data(buf), format: nil) {
                if let b = v as? Bool { return b }
                if let n = v as? NSNumber { return n.boolValue }
            }
        }
        guard spotlight, let item = MDItemCreate(nil, path as CFString) else { return false }
        if let v = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) {
            if let b = v as? Bool { return b }
            if let n = v as? NSNumber { return n.boolValue }
        }
        return false
    }

    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func group(name: String, isFolder: Bool, isPackage: Bool, screenCapture: Bool) -> DeskGroup {
        if screenCapture || looksLikeScreenshot(name: name) { return .screenshots }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "app" || installerExtensions.contains(ext) { return .installers }
        if isFolder && !isPackage { return .folders }
        if archiveExtensions.contains(ext) { return .archives }
        if documentExtensions.contains(ext) { return .documents }
        if let t = UTType(filenameExtension: ext) {
            if t.conforms(to: .image) { return .images }
            if t.conforms(to: .audiovisualContent) { return .media }
            if t.conforms(to: .archive) { return .archives }
            if t.conforms(to: .text) || t.conforms(to: .pdf) || t.conforms(to: .presentation)
                || t.conforms(to: .spreadsheet) { return .documents }
        }
        if isPackage { return .documents }  // .pages, .key, .rtfd и прочие документы-пакеты
        return .other
    }
}

// MARK: - Обход папки

enum ScanError: Error, Equatable {
    case denied
    case failed(String)
}

enum Scanner {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey,
        .addedToDirectoryDateKey, .totalFileAllocatedSizeKey, .fileSizeKey,
    ]

    /// Только верхний уровень `root`, без скрытых файлов и `.localized`. В папки не заходим (кроме подсчёта размера),
    /// ссылки не раскрываем.
    static func scan(_ root: URL, installed: [InstalledApp]? = nil, spotlight: Bool = true) throws -> [Entry] {
        let fm = FileManager.default
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch let e as CocoaError where e.code == .fileReadNoPermission {
            throw ScanError.denied
        } catch let e as NSError where e.domain == NSPOSIXErrorDomain && (e.code == Int(EPERM) || e.code == Int(EACCES)) {
            throw ScanError.denied
        } catch {
            throw ScanError.failed(error.localizedDescription)
        }
        var out: [Entry] = []
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name == ".localized" { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let link = v.isSymbolicLink == true
            let dir = !link && v.isDirectory == true
            let pkg = dir && v.isPackage == true
            let size = dir ? folderSize(url) : Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            let shot = !dir && !link && isMedia(name) && Classifier.isScreenCapture(url, spotlight: spotlight)
            var e = Entry(url: url,
                          group: link ? .other : Classifier.group(name: name, isFolder: dir, isPackage: pkg, screenCapture: shot),
                          size: size, isFolder: dir && !pkg, isSymlink: link,
                          created: v.creationDate, modified: v.contentModificationDate,
                          lastUsed: spotlight ? Classifier.lastUsed(url) : nil, added: v.addedToDirectoryDate)
            if let installed, e.isInstaller || e.group == .archives {
                e.installedMatch = Installed.match(name, in: installed)?.name
            }
            out.append(e)
        }
        return out.sorted { $0.size > $1.size }
    }

    private static func isMedia(_ name: String) -> Bool {
        guard let t = UTType(filenameExtension: (name as NSString).pathExtension) else { return false }
        return t.conforms(to: .image) || t.conforms(to: .movie)
    }

    /// Сумма размеров внутри папки (ссылки не раскрываются — так обходит FileManager).
    static func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let k: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey]
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: k, options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            if let v = try? f.resourceValues(forKeys: Set(k)) { total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0) }
        }
        return total
    }
}

// MARK: - «Уже установлено»

struct InstalledApp: Sendable, Hashable {
    let name: String   // «Google Chrome»
    let key: String    // «googlechrome»
}

enum Installed {
    static func standardDirs(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"),
         home.appendingPathComponent("Applications")]
    }

    static func list(in dirs: [URL]) -> [InstalledApp] {
        var out: Set<InstalledApp> = []
        for d in dirs {
            for n in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where n.hasSuffix(".app") {
                let name = String(n.dropLast(4))
                let k = key(name)
                if k.count >= 3 { out.insert(InstalledApp(name: name, key: k)) }
            }
        }
        return Array(out)
    }

    /// Слова, которые ничего не говорят о самом приложении: «Installer», «universal», «macOS», версии.
    private static let noise: Set<String> = ["installer", "install", "setup", "universal", "arm", "aarch", "intel", "x",
                                             "mac", "macos", "os", "osx", "darwin", "full", "latest", "release", "stable",
                                             "beta", "update", "apple", "silicon", "dmg", "pkg", "mpkg", "app", "zip",
                                             "download", "v", "signed", "amd", "win"]

    /// «zoomusInstallerFull.pkg» → «zoomus», «Google Chrome» → «googlechrome», «Telegram-macOS-11.2.dmg» → «telegram».
    static func key(_ raw: String) -> String {
        var s = raw
        for ext in ["dmg", "pkg", "mpkg", "zip", "app", "gz", "tar"] where (s as NSString).pathExtension.lowercased() == ext {
            s = (s as NSString).deletingPathExtension
        }
        var words: [String] = []
        var cur = ""
        var prevLower = false
        for ch in s {
            if ch.isLetter {
                if ch.isUppercase && prevLower { words.append(cur); cur = "" }
                cur.append(ch)
                prevLower = ch.isLowercase
            } else {
                if !cur.isEmpty { words.append(cur); cur = "" }
                prevLower = false
            }
        }
        if !cur.isEmpty { words.append(cur) }
        return words.map { $0.lowercased() }.filter { !noise.contains($0) }.joined()
    }

    static func match(_ fileName: String, in apps: [InstalledApp]) -> InstalledApp? {
        let k = key(fileName)
        guard k.count >= 3 else { return nil }
        if let exact = apps.first(where: { $0.key == k }) { return exact }
        // «telegramdesktop» ↔ «telegram»: одно начинается с другого, общая часть не короче 4 букв.
        return apps.filter { a in
            let (short, long) = a.key.count <= k.count ? (a.key, k) : (k, a.key)
            return short.count >= 4 && long.hasPrefix(short)
        }.max { $0.key.count < $1.key.count }
    }
}

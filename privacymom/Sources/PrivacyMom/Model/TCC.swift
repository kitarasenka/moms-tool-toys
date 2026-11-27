import Foundation
import SQLite3

// MARK: - Где лежат базы разрешений

enum TCCPaths {
    static let user = Paths.appSupport.appendingPathComponent("com.apple.TCC/TCC.db")
    static let system = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")

    /// `--demo-tcc <файл>` — показать вместо настоящих баз подготовленный файл (для проверки экрана
    /// на Mac без полного доступа к диску). Только чтение.
    static let demo: URL? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--demo-tcc"), i + 1 < a.count else { return nil }
        return URL(fileURLWithPath: a[i + 1])
    }()
}

// MARK: - Службы

struct TCCService: Sendable {
    let key: String          // kTCCServiceCamera
    let title: String
    let icon: String
    let pane: String         // Privacy_* в Системных настройках
    let order: Int

    /// Имя для `tccutil reset`: без префикса kTCCService.
    var tccutilName: String { key.hasPrefix("kTCCService") ? String(key.dropFirst("kTCCService".count)) : key }

    static func lookup(_ key: String) -> TCCService {
        if let s = known.first(where: { $0.key == key }) { return s }
        let short = key.hasPrefix("kTCCService") ? String(key.dropFirst("kTCCService".count)) : key
        return TCCService(key: key, title: short, icon: "questionmark.circle", pane: "Privacy", order: 1000)
    }

    static let known: [TCCService] = [
        .init(key: "kTCCServiceCamera", title: String(localized: "Камера"), icon: "camera", pane: "Privacy_Camera", order: 0),
        .init(key: "kTCCServiceMicrophone", title: String(localized: "Микрофон"), icon: "mic", pane: "Privacy_Microphone", order: 1),
        .init(key: "kTCCServiceScreenCapture", title: String(localized: "Запись экрана"), icon: "rectangle.dashed.badge.record", pane: "Privacy_ScreenCapture", order: 2),
        .init(key: "kTCCServiceAccessibility", title: String(localized: "Универсальный доступ"), icon: "accessibility", pane: "Privacy_Accessibility", order: 3),
        .init(key: "kTCCServiceListenEvent", title: String(localized: "Мониторинг ввода"), icon: "keyboard", pane: "Privacy_ListenEvent", order: 4),
        .init(key: "kTCCServicePostEvent", title: String(localized: "Управление вводом"), icon: "keyboard.badge.ellipsis", pane: "Privacy_Accessibility", order: 5),
        .init(key: "kTCCServiceSystemPolicyAllFiles", title: String(localized: "Полный доступ к диску"), icon: "internaldrive", pane: "Privacy_AllFiles", order: 6),
        .init(key: "kTCCServiceSystemPolicyDocumentsFolder", title: String(localized: "Папка «Документы»"), icon: "doc", pane: "Privacy_FilesAndFolders", order: 7),
        .init(key: "kTCCServiceSystemPolicyDownloadsFolder", title: String(localized: "Папка «Загрузки»"), icon: "arrow.down.circle", pane: "Privacy_FilesAndFolders", order: 8),
        .init(key: "kTCCServiceSystemPolicyDesktopFolder", title: String(localized: "Рабочий стол"), icon: "menubar.dock.rectangle", pane: "Privacy_FilesAndFolders", order: 9),
        .init(key: "kTCCServiceSystemPolicyRemovableVolumes", title: String(localized: "Съёмные тома"), icon: "externaldrive", pane: "Privacy_FilesAndFolders", order: 10),
        .init(key: "kTCCServiceSystemPolicyNetworkVolumes", title: String(localized: "Сетевые тома"), icon: "externaldrive.connected.to.line.below", pane: "Privacy_FilesAndFolders", order: 11),
        .init(key: "kTCCServiceFileProviderDomain", title: String(localized: "Облачные хранилища"), icon: "icloud", pane: "Privacy_FilesAndFolders", order: 12),
        .init(key: "kTCCServiceAddressBook", title: String(localized: "Контакты"), icon: "person.crop.circle", pane: "Privacy_Contacts", order: 13),
        .init(key: "kTCCServiceCalendar", title: String(localized: "Календари"), icon: "calendar", pane: "Privacy_Calendars", order: 14),
        .init(key: "kTCCServiceReminders", title: String(localized: "Напоминания"), icon: "checklist", pane: "Privacy_Reminders", order: 15),
        .init(key: "kTCCServicePhotos", title: String(localized: "Фото"), icon: "photo.on.rectangle", pane: "Privacy_Photos", order: 16),
        .init(key: "kTCCServiceMediaLibrary", title: String(localized: "Медиатека"), icon: "music.note", pane: "Privacy_Media", order: 17),
        .init(key: "kTCCServiceBluetoothAlways", title: "Bluetooth", icon: "dot.radiowaves.left.and.right", pane: "Privacy_Bluetooth", order: 18),
        .init(key: "kTCCServiceAppleEvents", title: String(localized: "Автоматизация"), icon: "gearshape.2", pane: "Privacy_Automation", order: 19),
        .init(key: "kTCCServiceLocalNetwork", title: String(localized: "Локальная сеть"), icon: "network", pane: "Privacy_LocalNetwork", order: 20),
        .init(key: "kTCCServiceSystemPolicyAppBundles", title: String(localized: "Управление приложениями"), icon: "app.badge", pane: "Privacy_AppBundles", order: 21),
        .init(key: "kTCCServiceSystemPolicyAppData", title: String(localized: "Данные других приложений"), icon: "folder.badge.person.crop", pane: "Privacy", order: 22),
        .init(key: "kTCCServiceDeveloperTool", title: String(localized: "Инструменты разработчика"), icon: "hammer", pane: "Privacy_DevTools", order: 23),
        .init(key: "kTCCServiceSpeechRecognition", title: String(localized: "Распознавание речи"), icon: "waveform", pane: "Privacy_SpeechRecognition", order: 24),
        .init(key: "kTCCServiceFocusStatus", title: String(localized: "Статус фокусирования"), icon: "moon", pane: "Privacy_Focus", order: 25),
        .init(key: "kTCCServiceUserAvailability", title: String(localized: "Статус фокусирования"), icon: "moon", pane: "Privacy_Focus", order: 25),
        .init(key: "kTCCServiceWillow", title: String(localized: "Дом"), icon: "house", pane: "Privacy_HomeKit", order: 26),
        .init(key: "kTCCServiceLiverpool", title: String(localized: "Службы синхронизации (системное)"), icon: "arrow.triangle.2.circlepath", pane: "Privacy", order: 900),
        .init(key: "kTCCServiceUbiquity", title: String(localized: "iCloud Drive (системное)"), icon: "icloud", pane: "Privacy", order: 901),
    ]
}

// MARK: - Записи

enum TCCAuth: Sendable, Equatable {
    case denied, allowed, limited, unknown(Int)

    init(_ v: Int) {
        switch v {
        case 0: self = .denied
        case 2: self = .allowed
        case 3: self = .limited
        default: self = .unknown(v)
        }
    }

    var title: String {
        switch self {
        case .denied: String(localized: "запрещено")
        case .allowed: String(localized: "разрешено")
        case .limited: String(localized: "ограничено")
        case .unknown(let v): String(localized: "код \(v)")
        }
    }

    var isGranted: Bool { self == .allowed || self == .limited }
}

struct TCCEntry: Identifiable, Sendable {
    enum Source: String, Sendable { case user = "пользователь", system = "система" } // l10n:skip

    var service: String
    var client: String
    var clientIsPath: Bool
    var auth: TCCAuth
    var modified: Date?
    var target: String?       // для AppleEvents — bundle id приложения, которым управляют
    var source: Source

    var id: String { "\(source.rawValue)|\(service)|\(client)|\(target ?? "")" }
    var info: TCCService { TCCService.lookup(service) }
}

struct TCCSnapshot: Sendable {
    var entries: [TCCEntry] = []
    var userReadable = false
    var systemReadable = false
    var errors: [String] = []

    func granted(_ service: String) -> Int {
        Set(entries.filter { $0.service == service && $0.auth.isGranted }.map(\.client)).count
    }
}

// MARK: - Чтение базы

enum TCCReader {
    enum ReadError: Error, CustomStringConvertible {
        case open(String), query(String), noTable

        var description: String {
            switch self {
            case .open(let m): String(localized: "не открыть: \(m)")
            case .query(let m): String(localized: "ошибка запроса: \(m)")
            case .noTable: String(localized: "нет таблицы access")
            }
        }
    }

    static func snapshot() -> TCCSnapshot {
        var s = TCCSnapshot()
        if let demo = TCCPaths.demo {
            do { s.entries = try read(demo, source: .user); s.userReadable = true; s.systemReadable = true }
            catch { s.errors.append("\(demo.path): \(error)") }
            return s
        }
        let dbs: [(URL, TCCEntry.Source)] = [(TCCPaths.user, .user), (TCCPaths.system, .system)]
        for (url, src) in dbs {
            do {
                s.entries += try read(url, source: src)
                if src == .user { s.userReadable = true } else { s.systemReadable = true }
            } catch {
                s.errors.append("\(Paths.pretty(url)): \(error)")
            }
        }
        return s
    }

    /// Только чтение: `mode=ro&immutable=1` — SQLite не создаёт журналов и ничего не блокирует.
    static func read(_ url: URL, source: TCCEntry.Source) throws -> [TCCEntry] {
        var db: OpaquePointer?
        var comps = URLComponents()
        comps.scheme = "file"
        comps.path = url.path
        comps.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        let uri = comps.string ?? "file:\(url.path)?mode=ro&immutable=1"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { sqlite3_close(db) }
        guard rc == SQLITE_OK, let db else {
            throw ReadError.open(db.map { String(cString: sqlite3_errmsg($0)) } ?? String(localized: "код \(rc)"))
        }

        // Схема меняется от версии к версии: смотрим, какие колонки есть.
        let cols = try columns(db)
        guard !cols.isEmpty else { throw ReadError.noTable }
        func pick(_ name: String) -> String { cols.contains(name) ? name : "NULL" }
        let authCol = cols.contains("auth_value") ? "auth_value" : (cols.contains("allowed") ? "(allowed * 2)" : "NULL")
        let sql = """
            SELECT \(pick("service")), \(pick("client")), \(pick("client_type")), \(authCol),
                   \(pick("last_modified")), \(pick("indirect_object_identifier")) FROM access
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ReadError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        func int(_ i: Int32) -> Int? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
        }

        var out: [TCCEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let service = text(0), let client = text(1) else { continue }
            let target = text(5).flatMap { $0 == "UNUSED" || $0.isEmpty ? nil : $0 }
            out.append(TCCEntry(
                service: service, client: client, clientIsPath: int(2) == 1,
                auth: TCCAuth(int(3) ?? -1),
                modified: int(4).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                target: target, source: source))
        }
        return out
    }

    private static func columns(_ db: OpaquePointer) throws -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(access)", -1, &stmt, nil) == SQLITE_OK else {
            throw ReadError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = sqlite3_column_text(stmt, 1) { names.insert(String(cString: p)) }
        }
        return names
    }
}

// MARK: - Сброс

enum TCCReset {
    /// Аргументы для `tccutil reset`. Для программ без bundle id (запись по пути) сброс невозможен.
    static func arguments(for e: TCCEntry) -> [String]? {
        guard !e.clientIsPath, !e.client.isEmpty else { return nil }
        return ["reset", e.info.tccutilName, e.client]
    }

    static func reset(_ e: TCCEntry) -> Shell.Result {
        if TCCPaths.demo != nil { return .init(ok: false, output: String(localized: "демо-режим, ничего не сброшено")) }
        guard let args = arguments(for: e) else {
            return .init(ok: false, output: String(localized: "Эта запись сделана для программы по пути, а не для приложения — tccutil её не сбрасывает."))
        }
        return Shell.run("/usr/bin/tccutil", args)
    }
}

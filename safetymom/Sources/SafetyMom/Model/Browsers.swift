import AppKit
import Foundation
import SQLite3

// MARK: - Каталог браузеров

enum BrowserEngine: Sendable {
    /// Chromium: профили `Default`, `Profile N` в папке данных (у старой Opera — сама папка).
    case chromium(data: String, scheme: String)
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
        .init(id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome", engine: .chromium(data: "Google/Chrome", scheme: "chrome")),
        .init(id: "yandex", name: "Яндекс Браузер", bundleID: "ru.yandex.desktop.yandex-browser",
              engine: .chromium(data: "Yandex/YandexBrowser", scheme: "browser")),
        .init(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox", engine: .firefox),
        .init(id: "edge", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", engine: .chromium(data: "Microsoft Edge", scheme: "edge")),
        .init(id: "brave", name: "Brave", bundleID: "com.brave.Browser", engine: .chromium(data: "BraveSoftware/Brave-Browser", scheme: "brave")),
        .init(id: "arc", name: "Arc", bundleID: "company.thebrowser.Browser", engine: .chromium(data: "Arc/User Data", scheme: "arc")),
        .init(id: "opera", name: "Opera", bundleID: "com.operasoftware.Opera", engine: .chromium(data: "com.operasoftware.Opera", scheme: "opera")),
        .init(id: "vivaldi", name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", engine: .chromium(data: "Vivaldi", scheme: "vivaldi")),
    ]

    var isChromium: Bool { if case .chromium = engine { true } else { false } }

    /// Страница расширений браузера — удалять расширения человек будет там сам.
    var extensionsPage: String? {
        switch engine {
        case .chromium(_, let s): "\(s)://extensions"
        case .firefox: "about:addons"
        case .safari: nil
        }
    }

    var notificationsPage: String? {
        switch engine {
        case .chromium(_, let s): s == "browser" ? "browser://settings/content/notifications" : "\(s)://settings/content/notifications"
        case .firefox: "about:preferences#privacy"
        case .safari: nil
        }
    }
}

/// Корни путей (в самопроверке — временная папка с поддельными профилями).
struct BrowserRoots: Sendable {
    var appSupport: URL
    var safari: URL

    static let real = BrowserRoots(appSupport: Paths.appSupport, safari: Paths.library.appendingPathComponent("Safari"))
}

struct BrowserProfile: Sendable, Hashable {
    var dir: URL
    var name: String
}

// MARK: - Расширения

enum ExtFlag: String, Sendable, CaseIterable {
    case allSites, proxy, management, debugger, nativeMessaging, cookies, history
    case notStore, developer, installedByApp, recent

    var title: String {
        switch self {
        case .allSites: "видит все сайты"
        case .proxy: "меняет прокси"
        case .management: "управляет расширениями"
        case .debugger: "отладчик"
        case .nativeMessaging: "связь с программой на Mac"
        case .cookies: "cookies"
        case .history: "история"
        case .notStore: "не из магазина"
        case .developer: "режим разработчика"
        case .installedByApp: "поставлено программой"
        case .recent: "недавно"
        }
    }

    var explain: String {
        switch self {
        case .allSites: "Может читать и менять всё на любом сайте, включая почту и банк. Для блокировщиков рекламы и менеджеров паролей это нормально."
        case .proxy: "Может пустить весь интернет через чужой сервер — так подменяют сайты и рекламу."
        case .management: "Может включать, выключать и прятать другие расширения."
        case .debugger: "Полный контроль над вкладками — нужен только разработчикам."
        case .nativeMessaging: "Общается с программой, установленной на Mac (например, с менеджером паролей)."
        case .cookies: "Может читать cookies — то, чем сайты помнят, что вы вошли."
        case .history: "Видит историю посещений."
        case .notStore: "Установлено не из магазина расширений — его никто не проверял."
        case .developer: "Загружено из папки в режиме разработчика."
        case .installedByApp: "Его поставили не вы, а другая программа или политика — так часто ставят рекламные расширения."
        case .recent: "Появилось за последние две недели."
        }
    }

    var isRisky: Bool { [.proxy, .management, .debugger, .notStore, .developer, .installedByApp].contains(self) }
}

struct BrowserExtension: Identifiable, Sendable {
    var extID: String
    var name: String
    var version: String
    var profile: String
    var enabled: Bool
    var installed: Date?
    var flags: [ExtFlag]
    var level: Level
    var id: String { "\(profile)|\(extID)" }
}

// MARK: - Уведомления от сайтов

struct SiteNotification: Identifiable, Sendable, Hashable {
    var key: String          // как записано в настройках браузера (для Chromium — «https://site:443,*»)
    var host: String
    var profile: String
    var prefs: URL?          // файл Preferences профиля Chromium — только для них можно снять разрешение
    var since: Date?
    var level: Level         // ok — знакомый сайт, warn — незнакомый, danger — похоже на спам
    var id: String { "\(profile)|\(key)" }

    var reason: String {
        switch level {
        case .ok: "Известный сервис — уведомления от него обычно нужны."
        case .danger: "Похоже на спам: такие сайты присылают «Ваш Mac заражён!», «Вы выиграли!» и рекламу."
        default: "Незнакомый сайт. Если не помните, что разрешали ему уведомления, — запретите."
        }
    }
}

struct BrowserReport: Identifiable, Sendable {
    var def: BrowserDef
    var installed: Bool
    var running: Bool
    var profiles: [BrowserProfile]
    var extensions: [BrowserExtension] = []
    var notifications: [SiteNotification] = []
    var notificationsReadable = true   // false — список не прочитать (Safari без полного доступа к диску)
    var notificationsNote: String?     // почему список может быть неполным
    var extensionsNote: String?
    var id: String { def.id }

    var canRevoke: Bool { def.isChromium }
    var worstExtension: Level { extensions.map(\.level).max() ?? .ok }
    var worstNotification: Level { notificationsReadable ? (notifications.map(\.level).max() ?? .ok) : .unknown }
}

// MARK: - Сканер

enum BrowserScanner {
    static func reports(roots: BrowserRoots = .real, fullDiskAccess: Bool) -> [BrowserReport] {
        BrowserDef.all.compactMap { def in
            let installed = Apps.url(def.bundleID) != nil
            var r = report(def, roots: roots, fullDiskAccess: fullDiskAccess)
            guard installed || !r.profiles.isEmpty || def.engine.isSafari else { return nil }
            r.installed = installed
            r.running = Apps.isRunning(def.bundleID)
            return r
        }
    }

    static func report(_ def: BrowserDef, roots: BrowserRoots, fullDiskAccess: Bool) -> BrowserReport {
        switch def.engine {
        case .chromium(let data, _):
            let root = roots.appSupport.appendingPathComponent(data, isDirectory: true)
            let profiles = chromiumProfiles(root)
            var r = BrowserReport(def: def, installed: false, running: false, profiles: profiles)
            for p in profiles {
                r.extensions += chromiumExtensions(p)
                r.notifications += chromiumNotifications(p)
            }
            return r
        case .firefox:
            let profiles = firefoxProfiles(roots.appSupport.appendingPathComponent("Firefox", isDirectory: true))
            var r = BrowserReport(def: def, installed: false, running: false, profiles: profiles)
            for p in profiles {
                r.extensions += firefoxExtensions(p)
                r.notifications += firefoxNotifications(p)
            }
            r.notificationsNote = "Снять разрешение в Firefox можно в его настройках: «Приватность и защита» → «Разрешения» → «Уведомления» → «Параметры…»."
            return r
        case .safari:
            var r = BrowserReport(def: def, installed: true, running: false, profiles: [])
            r.extensions = safariExtensions(Shell.run("/usr/bin/pluginkit", ["-mAvv", "-p", "com.apple.Safari.web-extension"], timeout: 8).output)
                + safariExtensions(Shell.run("/usr/bin/pluginkit", ["-mAvv", "-p", "com.apple.Safari.extension"], timeout: 8).output)
            r.extensionsNote = "Включены ли они в самом Safari, видно в Safari → Настройки → Расширения."
            if fullDiskAccess {
                r.notifications = safariNotifications(roots.safari.appendingPathComponent("UserNotificationPermissions.plist"))
            } else {
                r.notificationsReadable = false
            }
            r.notificationsNote = (fullDiskAccess ? "" : "Без полного доступа к диску список Safari не прочитать. ")
                + "Снять разрешение: Safari → Настройки → Веб-сайты → Уведомления, или Системные настройки → Уведомления."
            return r
        }
    }

    // MARK: Chromium

    static func chromiumProfiles(_ root: URL) -> [BrowserProfile] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let localState = (try? Data(contentsOf: root.appendingPathComponent("Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let cache = localState?.dict("profile")?.dict("info_cache") ?? [:]
        var out: [BrowserProfile] = []
        for name in items.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        where name == "Default" || name.hasPrefix("Profile ") {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: dir.appendingPathComponent("Preferences").path) else { continue }
            let display = (cache[name] as? [String: Any])?["name"] as? String
            out.append(BrowserProfile(dir: dir, name: display.map { $0.isEmpty ? name : $0 } ?? (name == "Default" ? "Основной" : name)))
        }
        // Старая Opera: профиль — сама папка данных.
        if out.isEmpty, fm.fileExists(atPath: root.appendingPathComponent("Preferences").path) {
            out.append(BrowserProfile(dir: root, name: "Основной"))
        }
        return out
    }

    static func json(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// Время Chromium: микросекунды с 1601-01-01 (строкой или числом).
    static func chromiumDate(_ v: Any?) -> Date? {
        let us: Double?
        if let s = v as? String { us = Double(s) } else if let n = v as? NSNumber { us = n.doubleValue } else { us = nil }
        guard let us, us > 0 else { return nil }
        return Date(timeIntervalSince1970: us / 1_000_000 - 11_644_473_600)
    }

    static func chromiumNow(_ d: Date = .now) -> String {
        String(Int64((d.timeIntervalSince1970 + 11_644_473_600) * 1_000_000))
    }

    static func chromiumExtensions(_ p: BrowserProfile, now: Date = .now) -> [BrowserExtension] {
        // Настройки расширений лежат в Secure Preferences (новые версии) или в Preferences (старые).
        var settings: [String: Any] = [:]
        for f in ["Preferences", "Secure Preferences"] {
            if let s = json(p.dir.appendingPathComponent(f))?.dict("extensions")?.dict("settings") {
                settings.merge(s) { _, secure in secure }
            }
        }
        let extRoot = p.dir.appendingPathComponent("Extensions", isDirectory: true)
        var out: [BrowserExtension] = []
        for (id, raw) in settings {
            guard let s = raw as? [String: Any] else { continue }
            let location = (s["location"] as? NSNumber)?.intValue ?? 0
            if location == 5 || location == 10 { continue }                 // встроенные части браузера
            if s.bool("was_installed_by_default") == true { continue }       // «Документы офлайн» и т. п.
            let dir: URL? = (s["path"] as? String).map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : extRoot.appendingPathComponent($0) }
            let manifest = (s["manifest"] as? [String: Any]) ?? dir.flatMap { json($0.appendingPathComponent("manifest.json")) }
            guard let manifest else { continue }                             // следы удалённых расширений
            var name = manifest["name"] as? String ?? id
            if name.hasPrefix("__MSG_"), let dir { name = localized(name, dir: dir, defaultLocale: manifest["default_locale"] as? String) ?? id }
            let reasons = s["disable_reasons"] as? [Any] ?? []
            let state = (s["state"] as? NSNumber)?.intValue
            let enabled = reasons.isEmpty && state != 0
            let fromStore = s.bool("from_webstore") == true || storeUpdateURL(manifest["update_url"] as? String)
            let installed = chromiumDate(s["first_install_time"] ?? s["install_time"])
            var perms = strings(manifest["permissions"]) + strings(manifest["host_permissions"])
            for cs in manifest["content_scripts"] as? [[String: Any]] ?? [] { perms += strings(cs["matches"]) }
            var flags = permissionFlags(perms)
            if location == 4 { flags.append(.developer) } else {
                if [2, 3, 6, 7, 8, 9].contains(location) { flags.append(.installedByApp) }
                if !fromStore { flags.append(.notStore) }
            }
            if let installed, now.timeIntervalSince(installed) < 14 * 86400 { flags.append(.recent) }
            out.append(BrowserExtension(extID: id, name: name, version: manifest["version"] as? String ?? "",
                                        profile: p.name, enabled: enabled, installed: installed,
                                        flags: flags, level: extensionLevel(flags)))
        }
        return out.sorted { ($0.level, $1.name) > ($1.level, $0.name) }
    }

    static func storeUpdateURL(_ s: String?) -> Bool {
        guard let s else { return false }
        return ["clients2.google.com", "edge.microsoft.com", "extension-updates.opera.com", "addons.opera.com"].contains { s.contains($0) }
    }

    static func strings(_ v: Any?) -> [String] {
        (v as? [Any])?.compactMap { $0 as? String } ?? []
    }

    static let allSitesPatterns: Set<String> = ["<all_urls>", "*://*/*", "http://*/*", "https://*/*", "*://*/", "http://*/", "https://*/"]

    static func permissionFlags(_ perms: [String]) -> [ExtFlag] {
        let set = Set(perms)
        var f: [ExtFlag] = []
        if !set.isDisjoint(with: allSitesPatterns) { f.append(.allSites) }
        if set.contains("proxy") { f.append(.proxy) }
        if set.contains("management") { f.append(.management) }
        if set.contains("debugger") { f.append(.debugger) }
        if set.contains("nativeMessaging") { f.append(.nativeMessaging) }
        if set.contains("cookies") { f.append(.cookies) }
        if set.contains("history") { f.append(.history) }
        return f
    }

    /// Красный — не из магазина (никто не проверял) и при этом с широкими правами;
    /// жёлтый — что-то одно: не из магазина, поставлено другой программой (Adobe, антивирусы — но и рекламщики),
    /// прокси/отладчик или «видит все сайты» у свежего расширения. «Управляет расширениями» само по себе не тревожно —
    /// так делают менеджеры паролей.
    static func extensionLevel(_ flags: [ExtFlag]) -> Level {
        let f = Set(flags)
        let unchecked = !f.isDisjoint(with: [.notStore, .developer])
        let dangerous = !f.isDisjoint(with: [.proxy, .debugger])
        if unchecked && (dangerous || !f.isDisjoint(with: [.allSites, .management])) { return .danger }
        if unchecked || dangerous || f.contains(.installedByApp) || (f.contains(.allSites) && f.contains(.recent)) { return .warn }
        return .ok
    }

    /// `__MSG_appName__` → текст из `_locales/<ru|default|en>/messages.json` (ключи без учёта регистра).
    static func localized(_ msg: String, dir: URL, defaultLocale: String?) -> String? {
        let key = msg.replacingOccurrences(of: "__MSG_", with: "").replacingOccurrences(of: "__", with: "").lowercased()
        for loc in ["ru", defaultLocale, "en", "en_US"].compactMap({ $0 }) {
            guard let m = json(dir.appendingPathComponent("_locales/\(loc)/messages.json")) else { continue }
            for (k, v) in m where k.lowercased() == key {
                if let t = (v as? [String: Any])?["message"] as? String { return t }
            }
        }
        return nil
    }

    static func chromiumNotifications(_ p: BrowserProfile) -> [SiteNotification] {
        let prefsURL = p.dir.appendingPathComponent("Preferences")
        guard let ex = json(prefsURL)?.dict("profile")?.dict("content_settings")?.dict("exceptions")?.dict("notifications") else { return [] }
        return ex.compactMap { key, v in
            guard let d = v as? [String: Any], (d["setting"] as? NSNumber)?.intValue == 1 else { return nil }
            let host = Self.host(key)
            return SiteNotification(key: key, host: host, profile: p.name, prefs: prefsURL,
                                    since: chromiumDate(d["last_modified"]), level: siteLevel(host))
        }.sorted { ($0.level, $1.host) > ($1.level, $0.host) }
    }

    /// «https://www.site.com:443,*» → «site.com».
    static func host(_ key: String) -> String {
        var s = key.split(separator: ",").first.map(String.init) ?? key
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(of: "/") { s = String(s[..<i]) }
        if let i = s.lastIndex(of: ":"), !s.contains("]") { s = String(s[..<i]) }
        if s.hasPrefix("[*.]") { s.removeFirst(4) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s.lowercased()
    }

    static let knownSites = [
        "google.com", "youtube.com", "gmail.com", "yandex.ru", "ya.ru", "mail.ru", "rambler.ru", "vk.com", "ok.ru",
        "facebook.com", "messenger.com", "instagram.com", "whatsapp.com", "telegram.org", "twitter.com", "x.com",
        "linkedin.com", "discord.com", "slack.com", "zoom.us", "skype.com", "live.com", "outlook.com", "office.com",
        "microsoft.com", "teams.microsoft.com", "icloud.com", "apple.com", "claude.ai", "chatgpt.com", "openai.com",
        "notion.so", "github.com", "gosuslugi.ru", "sberbank.ru", "tbank.ru", "tinkoff.ru", "ozon.ru", "wildberries.ru",
        "avito.ru", "kinopoisk.ru", "chess.com", "trello.com", "asana.com", "figma.com", "pinterest.com", "reddit.com",
    ]

    static let spamWords = ["captcha", "robot", "verif", "allow", "push", "notif", "alert", "prize", "gift", "bonus",
                            "winner", "antivir", "virus", "clean", "protect", "dating", "lucky", "reward", "click"]
    static let spamTLDs: Set<String> = ["xyz", "top", "icu", "buzz", "online", "site", "click", "space", "live", "monster",
                                        "cyou", "rest", "sbs", "cfd", "quest", "bond", "cam", "tk", "ml", "ga", "cf", "gq",
                                        "pw", "work", "fun", "lol", "win", "bid", "loan", "date", "racing", "review", "stream"]

    static func siteLevel(_ host: String) -> Level {
        if knownSites.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .ok }
        let tld = host.split(separator: ".").last.map(String.init) ?? ""
        if spamTLDs.contains(tld) || spamWords.contains(where: { host.contains($0) }) { return .danger }
        return .warn
    }

    // MARK: Firefox

    static func firefoxProfiles(_ root: URL) -> [BrowserProfile] {
        let dir = root.appendingPathComponent("Profiles", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return items.sorted().compactMap { name in
            let p = dir.appendingPathComponent(name, isDirectory: true)
            let fm = FileManager.default
            guard fm.fileExists(atPath: p.appendingPathComponent("extensions.json").path)
                    || fm.fileExists(atPath: p.appendingPathComponent("permissions.sqlite").path) else { return nil }
            let short = name.split(separator: ".", maxSplits: 1).last.map(String.init) ?? name
            return BrowserProfile(dir: p, name: short)
        }
    }

    static func firefoxExtensions(_ p: BrowserProfile, now: Date = .now) -> [BrowserExtension] {
        guard let addons = json(p.dir.appendingPathComponent("extensions.json"))?["addons"] as? [[String: Any]] else { return [] }
        return addons.compactMap { a in
            guard a["type"] as? String == "extension", a["location"] as? String == "app-profile",
                  let id = a["id"] as? String, !id.hasSuffix("@mozilla.org"), !id.hasSuffix("@mozilla.com") else { return nil }
            let name = (a["defaultLocale"] as? [String: Any])?["name"] as? String ?? id
            let up = a["userPermissions"] as? [String: Any]
            var flags = permissionFlags(strings(up?["permissions"]) + strings(up?["origins"]))
            let signed = (a["signedState"] as? NSNumber)?.intValue ?? 0
            if signed < 2 { flags.append(.notStore) }
            let installed = (a["installDate"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            if let installed, now.timeIntervalSince(installed) < 14 * 86400 { flags.append(.recent) }
            let enabled = (a["active"] as? Bool ?? false) && !(a["userDisabled"] as? Bool ?? false)
            return BrowserExtension(extID: id, name: name, version: a["version"] as? String ?? "", profile: p.name,
                                    enabled: enabled, installed: installed, flags: flags, level: extensionLevel(flags))
        }
    }

    /// permissions.sqlite открывается только на чтение и «неизменяемой» — браузер может быть запущен.
    static func firefoxNotifications(_ p: BrowserProfile) -> [SiteNotification] {
        let path = p.dir.appendingPathComponent("permissions.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro&immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        let sql = "SELECT origin, modificationTime FROM moz_perms WHERE type = 'desktop-notification' AND permission = 1"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [SiteNotification] = []
        while sqlite3_step(st) == SQLITE_ROW {
            guard let c = sqlite3_column_text(st, 0) else { continue }
            let origin = String(cString: c)
            let ms = sqlite3_column_int64(st, 1)
            let host = host(origin)
            out.append(SiteNotification(key: origin, host: host, profile: p.name, prefs: nil,
                                        since: ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000) : nil, level: siteLevel(host)))
        }
        return out
    }

    // MARK: Safari

    /// Разбор `pluginkit -mAvv`: блок на расширение, первая строка — «+    id(версия)».
    static func safariExtensions(_ out: String) -> [BrowserExtension] {
        var result: [BrowserExtension] = []
        var cur: [String: String] = [:]
        var head = ""
        func flush() {
            guard !head.isEmpty else { return }
            let enabled = !head.hasPrefix("-")
            let idv = head.dropFirst().trimmingCharacters(in: .whitespaces)
            var id = idv, ver = ""
            if let o = idv.lastIndex(of: "("), idv.hasSuffix(")") {
                id = String(idv[..<o]); ver = String(idv[idv.index(after: o)..<idv.index(before: idv.endIndex)])
            }
            let parent = cur["Parent Bundle"]
            let name = cur["Display Name"] ?? parent.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? id
            let fromMAS = parent.map { FileManager.default.fileExists(atPath: $0 + "/Contents/_MASReceipt/receipt") } ?? false
            let flags: [ExtFlag] = fromMAS ? [] : [.notStore]
            // Расширения Safari подписаны и проверены Apple — «не из App Store» здесь лишь пометка.
            result.append(BrowserExtension(extID: id, name: name, version: ver, profile: "Safari", enabled: enabled,
                                           installed: nil, flags: flags, level: .ok))
            head = ""; cur = [:]
        }
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = String(line)
            if let f = l.first, ["+", "-", "!", "=", "?", " "].contains(f), !l.hasPrefix("\t"), !l.contains(" = ") {
                flush()
                head = l
            } else if let r = l.range(of: " = ") {
                cur[l[..<r.lowerBound].trimmingCharacters(in: .whitespaces)] = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return result.filter { !$0.extID.isEmpty && $0.extID != "(no matches)" && !$0.extID.contains("no matches") }
    }

    /// UserNotificationPermissions.plist: словарь «сайт → {Permission, Date}». Формат не документирован —
    /// читаем осторожно: разрешением считаем Permission == 1 или true.
    static func safariNotifications(_ url: URL) -> [SiteNotification] {
        guard let d = Plist.read(url.path) else { return [] }
        return d.compactMap { key, v in
            let e = v as? [String: Any]
            let allowed = e?.bool("Permission") ?? false
            guard allowed else { return nil }
            let h = host(key)
            return SiteNotification(key: key, host: h, profile: "Safari", prefs: nil, since: e?["Date"] as? Date, level: siteLevel(h))
        }
    }
}

extension BrowserEngine {
    var isSafari: Bool { if case .safari = self { true } else { false } }
}

// MARK: - Запрет уведомлений (Chromium)

enum RevokeError: LocalizedError {
    case browserRunning(String), unreadable, notFound, writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .browserRunning(let n): "Сначала закройте \(n) — иначе он перезапишет настройки при выходе."
        case .unreadable: "Не получилось прочитать настройки браузера."
        case .notFound: "Этого разрешения уже нет — возможно, его сняли в самом браузере."
        case .writeFailed(let e): "Не получилось сохранить настройки: \(e)"
        }
    }
}

enum NotificationRevoker {
    /// Ставит для сайтов «Запретить уведомления» в Preferences профиля Chromium.
    /// Только при закрытом браузере; перед записью — копия файла в `backupDir`; запись атомарная
    /// (временный файл рядом + замена), результат перепроверяется чтением.
    @discardableResult
    static func block(keys: [String], prefs: URL, backupDir: URL, label: String, browserRunning: Bool, browserName: String,
                      now: Date = .now) throws -> URL {
        if browserRunning { throw RevokeError.browserRunning(browserName) }
        guard let data = try? Data(contentsOf: prefs),
              var root = (try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers])) as? [String: Any],
              var profile = root["profile"] as? [String: Any],
              var cs = profile["content_settings"] as? [String: Any],
              var ex = cs["exceptions"] as? [String: Any],
              var notif = ex["notifications"] as? [String: Any] else { throw RevokeError.unreadable }
        var changed = 0
        for k in keys {
            guard var e = notif[k] as? [String: Any] else { continue }
            e["setting"] = 2
            e["last_modified"] = BrowserScanner.chromiumNow(now)
            notif[k] = e
            changed += 1
        }
        guard changed > 0 else { throw RevokeError.notFound }
        ex["notifications"] = notif; cs["exceptions"] = ex; profile["content_settings"] = cs; root["profile"] = profile

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
            let backup = backupDir.appendingPathComponent("\(label)-\(stamp)-Preferences.json")
            try data.write(to: backup, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)

            let out = try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
            guard (try? JSONSerialization.jsonObject(with: out)) is [String: Any] else { throw RevokeError.writeFailed("проверка не прошла") }
            let tmp = prefs.deletingLastPathComponent().appendingPathComponent(".Preferences.safetymom-\(UUID().uuidString)")
            try out.write(to: tmp)
            if let attrs = try? fm.attributesOfItem(atPath: prefs.path), let perm = attrs[.posixPermissions] {
                try? fm.setAttributes([.posixPermissions: perm], ofItemAtPath: tmp.path)
            }
            _ = try fm.replaceItemAt(prefs, withItemAt: tmp)
            pruneBackups(backupDir, keep: 30)
            return backup
        } catch let e as RevokeError {
            throw e
        } catch {
            throw RevokeError.writeFailed(error.localizedDescription)
        }
    }

    static func pruneBackups(_ dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = items.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for u in sorted.dropFirst(keep) { try? fm.removeItem(at: u) }
    }
}

import Foundation
import SQLite3

/// `SafetyMom --selftest` — разбор ответов системных команд на образцах и браузерные профили во временной
/// папке (включая запрет уведомлений с резервной копией). Настоящие настройки Mac и браузеров не трогаются.
enum SelfTest {
    nonisolated(unsafe) private static var ok = true

    private static func expect(_ cond: Bool, _ msg: String) {
        print((cond ? "✓ " : "✗ ") + msg)
        ok = ok && cond
    }

    static func run() -> Never {
        let sandbox = Paths.tmp.appendingPathComponent("safetymom-selftest-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        print("— Проверки системы")
        checks()
        print("— Порты")
        ports()
        print("— Сеть и профили")
        network()
        print("— Chromium")
        chromium(sandbox)
        print("— Firefox и Safari")
        firefoxSafari(sandbox)
        print("— Демо-данные")
        expect(!Demo.checks.isEmpty && !Demo.browsers.isEmpty, "демо-данные собираются")

        try? FileManager.default.removeItem(at: sandbox)
        print(ok ? "Всё в порядке" : "ЕСТЬ ОШИБКИ")
        exit(ok ? 0 : 1)
    }

    // MARK: Проверки

    private static func checks() {
        let S = SystemChecks.self
        expect(S.fileVault("FileVault is On.", laptop: true).level == .ok, "FileVault включён → зелёный")
        expect(S.fileVault("FileVault is Off.", laptop: true).level == .warn, "FileVault выключен → жёлтый")
        expect(S.fileVault("", laptop: false).level == .unknown, "FileVault без ответа → «не удалось»")
        expect(S.firewall("Firewall is enabled. (State = 1)").level == .ok, "файрвол включён")
        expect(S.firewall("Firewall is disabled. (State = 0)").level == .warn, "файрвол выключен → жёлтый")
        expect(S.gatekeeper("assessments enabled").level == .ok, "Gatekeeper включён")
        expect(S.gatekeeper("assessments disabled").level == .danger, "Gatekeeper выключен → красный")
        expect(S.sip("System Integrity Protection status: enabled.").level == .ok, "SIP включена")
        expect(S.sip("System Integrity Protection status: disabled.").level == .danger, "SIP выключена → красный")

        expect(S.screenLock("screenLock delay is immediate", screensaverIdle: 300, displaySleep: 10).level == .ok, "пароль сразу → зелёный")
        expect(S.screenLock("screenLock is off", screensaverIdle: 300, displaySleep: 10).level == .danger, "пароль не спрашивается → красный")
        expect(S.screenLock("screenLock delay is 3600 seconds", screensaverIdle: 300, displaySleep: 10).level == .warn, "пароль через час → жёлтый")
        expect(S.screenLock("screenLock delay is 5 seconds", screensaverIdle: 0, displaySleep: 0).level == .warn, "экран никогда не гаснет → жёлтый")
        expect(S.screenLock("", screensaverIdle: nil, displaySleep: nil).level == .unknown, "нет ответа → «не удалось»")
        expect(S.displaySleep(" sleep                 1\n displaysleep         10\n") == 10, "displaysleep из pmset")

        let cur = OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)
        func upd(_ list: [(String, String)], last: Date = .now) -> [String: Any] {
            ["RecommendedUpdates": list.map { ["Display Name": $0.0, "Display Version": $0.1, "Identifier": "MSU_UPDATE_x"] },
             "LastSuccessfulDate": last]
        }
        let pending = S.updates(prefs: upd([("macOS\u{a0}Tahoe\u{a0}26.7.3", "26.7.3"), ("macOS 27.2.1", "27.2.1"), ("macOS 26.7.1", "26.7.1")]), current: cur, now: .now)
        expect(pending.level == .warn && pending.status.contains("26.7.3"), "есть 26.7.3 → жёлтый, предлагается самое новое: \(pending.status)")
        expect(S.updates(prefs: upd([("macOS 27.2.1", "27.2.1")]), current: cur, now: .now).level == .ok, "только новая major-версия → зелёный")
        let old = OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0)
        expect(S.updates(prefs: upd([("macOS 27.1", "27.1")]), current: old, now: .now).level == .danger, "macOS 14 при вышедшей 27 → устарела (красный)")
        expect(S.updates(prefs: upd([("macOS 26.1", "26.1")]), current: old, now: .now).level == .ok, "macOS 14 при 26 — ещё поддерживается")
        expect(S.updates(prefs: upd([], last: .now.addingTimeInterval(-40 * 86400)), current: cur, now: .now).level == .warn, "давно не проверялись → жёлтый")
        expect(S.updates(prefs: nil, current: cur, now: .now).level == .unknown, "нет файла → «не удалось»")
        expect(S.generation(15) == 15 && S.generation(26) == 16, "поколения: 15 → 26 идут подряд")

        expect(S.autoUpdates(prefs: [:], commerce: nil).level == .ok, "автообновления по умолчанию → зелёный")
        expect(S.autoUpdates(prefs: ["CriticalUpdateInstall": false], commerce: nil).level == .danger, "защитные обновления выключены → красный")
        expect(S.autoUpdates(prefs: [:], commerce: ["AutoUpdate": 0]).level == .warn, "App Store вручную → жёлтый")

        let now = Date()
        func tm(_ days: Double, auto: Bool = true) -> [String: Any] {
            ["AutoBackup": auto, "Destinations": [["SnapshotDates": [now.addingTimeInterval(-days * 86400 - 3600), now.addingTimeInterval(-days * 86400)]]]]
        }
        expect(S.timeMachine(prefs: ["PreferencesVersion": 6], readable: true, destinationInfo: "tmutil: No destinations configured.", now: now).level == .warn, "Time Machine не настроена → жёлтый")
        expect(S.timeMachine(prefs: tm(2), readable: true, destinationInfo: "Name          : Backup\nKind : Local", now: now).level == .ok, "копия 2 дня назад → зелёный")
        expect(S.timeMachine(prefs: tm(10), readable: true, destinationInfo: nil, now: now).level == .warn, "копия 10 дней назад → жёлтый")
        expect(S.timeMachine(prefs: tm(40), readable: true, destinationInfo: nil, now: now).level == .danger, "копия 40 дней назад → красный")
        expect(S.timeMachine(prefs: tm(1, auto: false), readable: true, destinationInfo: nil, now: now).level == .warn, "только вручную → жёлтый")
        expect(S.timeMachine(prefs: nil, readable: false, destinationInfo: "", now: now).level == .unknown, "нет доступа → «не удалось»")
        expect(S.destinationNames("Name          : Мой диск\nKind          : Local\n") == ["Мой диск"], "имя диска из tmutil")

        expect(S.autoLogin(["autoLoginUser": "mama"], readable: true).level == .danger, "автовход → красный")
        expect(S.autoLogin([:], readable: true).level == .ok && S.autoLogin(nil, readable: false).level == .ok, "без автовхода → зелёный")
        expect(S.remote(open: []).level == .ok && S.remote(open: [5900]).level == .warn, "удалённый доступ: выкл → зелёный, общий экран → жёлтый")
        expect(S.xprotect(version: "5377", updated: now.addingTimeInterval(-120 * 86400), now: now).level == .warn, "XProtect 4 месяца без обновлений → жёлтый")
        expect(S.xprotect(version: nil, updated: nil, now: now).level == .unknown, "XProtect не найден → «не удалось»")

        let v = Verdict([S.sip("status: enabled."), S.firewall("disabled"), S.gatekeeper("assessments disabled")])
        expect(v.level == .danger && v.title.contains("1 пункт"), "итог — по худшей проверке: \(v.title)")
        let order = SystemChecks.sorted([S.sip("status: enabled."), S.firewall("disabled"), S.gatekeeper("assessments disabled")]).map(\.id)
        expect(order == ["gatekeeper", "firewall", "sip"], "сортировка: красное, жёлтое, зелёное")
    }

    // MARK: Порты

    private static func ports() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && listen(fd, 1) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        let port = UInt16(bigEndian: addr.sin_port)
        expect(bound && Ports.isListening(port), "открытый порт \(port) виден")
        close(fd)
        expect(!Ports.isListening(port), "закрытый порт не виден")
    }

    // MARK: Сеть

    private static func network() {
        let N = NetworkScanner.self
        expect(N.proxies(["FTPPassive": 1]).isEmpty, "без прокси — пусто")
        let p = N.proxies(["HTTPEnable": 1, "HTTPProxy": "10.0.0.5", "HTTPPort": 8080, "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://x/p.pac"])
        expect(p.count == 2 && p[0].address == "10.0.0.5:8080", "HTTP-прокси и PAC найдены")
        expect(N.classifyDNS("192.168.100.1").level == .ok && N.classifyDNS("1.1.1.1").level == .ok, "роутер и Cloudflare → зелёные")
        expect(N.classifyDNS("45.13.1.2").level == .warn && N.classifyDNS("127.0.0.1").level == .warn, "незнакомый и локальный DNS → жёлтые")
        expect(N.isPrivate("172.20.1.1") && !N.isPrivate("172.32.1.1") && N.isPrivate("fe80::1"), "частные адреса")
        expect(N.scutilDNS("resolver #1\n  nameserver[0] : 192.168.1.1\nresolver #2\n  nameserver[0] : 192.168.1.1\n  nameserver[1] : 8.8.8.8") == ["192.168.1.1", "8.8.8.8"], "scutil --dns без повторов")

        let hosts = """
        ##
        # Host Database
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1             localhost
        fe80::1%lo0 localhost
        0.0.0.0 ads.example.com   # реклама
        0.0.0.0 swscan.apple.com
        93.184.216.34 online.sberbank.ru
        10.0.0.7 dev.local
        """
        let h = N.hosts(hosts)
        expect(h.count == 4, "в hosts 4 нестандартных строки (стандартные пропущены): \(h.count)")
        expect(h.map(\.level) == [.ok, .warn, .danger, .warn], "блокировка рекламы — ок, обновлений Apple — жёлтый, подмена банка — красный")

        let sp = #"{"SPConfigurationProfileDataType":[{"_name":"Device (Installed)","_items":[{"_name":"Wi-Fi Work","spconfigprofile_organization":"ACME","spconfigprofile_install_date":"2026-01-02","_items":[{"_name":"payload"}]}]}]}"#
        let prof = N.profiles(json: Data(sp.utf8))
        expect(prof.count == 1 && prof[0].name == "Wi-Fi Work" && prof[0].organization == "ACME", "профиль из system_profiler")
        expect(N.profiles(json: Data(#"{"SPConfigurationProfileDataType":[]}"#.utf8)).isEmpty, "нет профилей — пусто")
        expect(N.mdmEnrolled("Enrolled via DEP: No\nMDM enrollment: No") == false && N.mdmEnrolled("MDM enrollment: Yes (User Approved)") == true, "MDM")
    }

    // MARK: Chromium

    private static func write(_ obj: Any, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: obj).write(to: url)
    }

    private static func chromium(_ sandbox: URL) {
        let roots = BrowserRoots(appSupport: sandbox.appendingPathComponent("AS"), safari: sandbox.appendingPathComponent("Safari"))
        let chrome = roots.appSupport.appendingPathComponent("Google/Chrome")
        let def = chrome.appendingPathComponent("Default")
        let oldInstall = BrowserScanner.chromiumNow(Date().addingTimeInterval(-200 * 86400))
        let newInstall = BrowserScanner.chromiumNow(Date().addingTimeInterval(-2 * 86400))
        write(["profile": ["info_cache": ["Default": ["name": "Мама"], "Profile 1": ["name": "Работа"]]]], chrome.appendingPathComponent("Local State"))
        let prefs: [String: Any] = [
            "profile": ["name": "Мама", "content_settings": ["exceptions": ["notifications": [
                "https://mail.google.com:443,*": ["setting": 1, "last_modified": "13370000000000000"],
                "https://win-prize.xyz:443,*": ["setting": 1],
                "https://recepty.example:443,*": ["setting": 1],
                "https://blocked.com:443,*": ["setting": 2],
            ]]]],
            "other": ["unicode": "Привет / ✓", "num": 1.5, "big": 13319896118022894, "flag": true, "nested": ["arr": [1, 2, 3]]],
        ]
        write(prefs, def.appendingPathComponent("Preferences"))
        let ext = def.appendingPathComponent("Extensions")
        write(["appName": ["message": "Search Plus"]], ext.appendingPathComponent("bbbb/2.0_0/_locales/en/messages.json"))
        write(["AppName": ["message": "Поиск Плюс"]], ext.appendingPathComponent("bbbb/2.0_0/_locales/ru/messages.json"))
        let unpacked = sandbox.appendingPathComponent("my-ext")
        write(["name": "Моё расширение", "version": "0.1", "permissions": ["storage"]], unpacked.appendingPathComponent("manifest.json"))
        write(["extensions": ["settings": [
            "aaaa": ["location": 1, "from_webstore": true, "path": "aaaa/1.0_0", "first_install_time": oldInstall,
                     "manifest": ["name": "AdBlock", "version": "1.0", "permissions": ["<all_urls>", "storage"]]],
            "bbbb": ["location": 1, "from_webstore": false, "path": "bbbb/2.0_0", "first_install_time": newInstall,
                     "manifest": ["name": "__MSG_appName__", "default_locale": "en", "version": "2.0", "permissions": ["proxy", "<all_urls>"]]],
            "cccc": ["location": 5, "manifest": ["name": "Chrome PDF Viewer"]],
            "dddd": ["disable_reasons": []],
            "eeee": ["location": 4, "path": unpacked.path],
            "ffff": ["location": 1, "from_webstore": true, "disable_reasons": [1], "path": "ffff/1_0",
                     "manifest": ["name": "Старое", "version": "1", "update_url": "https://clients2.google.com/service/update2/crx"]],
            "gggg": ["location": 6, "was_installed_by_default": true, "manifest": ["name": "Документы офлайн"]],
        ]]], def.appendingPathComponent("Secure Preferences"))
        write(["profile": ["name": "Работа"]], chrome.appendingPathComponent("Profile 1/Preferences"))

        let chromeDef = BrowserDef.all.first { $0.id == "chrome" }!
        let r = BrowserScanner.report(chromeDef, roots: roots, fullDiskAccess: false)
        expect(r.profiles.map(\.name) == ["Мама", "Работа"], "профили с именами из Local State: \(r.profiles.map(\.name))")
        let byHost = Dictionary(uniqueKeysWithValues: r.notifications.map { ($0.host, $0.level) })
        expect(r.notifications.count == 3, "разрешённых уведомлений 3 (запрещённые не в счёт): \(r.notifications.count)")
        expect(byHost["mail.google.com"] == .ok && byHost["win-prize.xyz"] == .danger && byHost["recepty.example"] == .warn,
               "знакомый — зелёный, спам — красный, незнакомый — жёлтый")
        expect(r.notifications.first?.host == "win-prize.xyz", "подозрительные — наверху")
        let exts = Dictionary(uniqueKeysWithValues: r.extensions.map { ($0.extID, $0) })
        expect(Set(exts.keys) == ["aaaa", "bbbb", "eeee", "ffff"], "встроенные, удалённые и предустановленные пропущены: \(exts.keys.sorted())")
        expect(exts["bbbb"]?.name == "Поиск Плюс", "__MSG_ имя из _locales/ru без учёта регистра: \(exts["bbbb"]?.name ?? "-")")
        expect(exts["bbbb"]?.level == .danger && exts["bbbb"]!.flags.contains(.recent), "не из магазина + прокси → красный, отмечено «недавно»")
        expect(exts["aaaa"]?.level == .ok && exts["aaaa"]!.flags == [.allSites], "AdBlock из магазина → зелёный (видит все сайты)")
        expect(exts["eeee"]?.name == "Моё расширение" && exts["eeee"]?.level == .warn, "распакованное: манифест с диска, жёлтый")
        expect(BrowserScanner.extensionLevel([.allSites, .management, .nativeMessaging]) == .ok, "менеджер паролей из магазина → зелёный")
        expect(BrowserScanner.extensionLevel([.allSites, .installedByApp]) == .warn, "поставлено программой из магазина → жёлтый")
        expect(exts["ffff"]?.enabled == false && exts["ffff"]?.level == .ok, "выключенное из магазина распознано")
        expect(BrowserScanner.host("https://www.Site.com:443,*") == "site.com" && BrowserScanner.host("[*.]ads.net,*") == "ads.net", "имя сайта из ключа")
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        expect(abs(BrowserScanner.chromiumDate(BrowserScanner.chromiumNow(d))!.timeIntervalSince(d)) < 0.001, "время Chromium туда-обратно")

        // Запрет уведомлений
        let prefsURL = def.appendingPathComponent("Preferences")
        let before = try! Data(contentsOf: prefsURL)
        let backups = sandbox.appendingPathComponent("Backups")
        var refused = false
        do { try NotificationRevoker.block(keys: ["https://win-prize.xyz:443,*"], prefs: prefsURL, backupDir: backups, label: "chrome-Default", browserRunning: true, browserName: "Chrome") }
        catch RevokeError.browserRunning { refused = true } catch {}
        expect(refused && (try! Data(contentsOf: prefsURL)) == before, "при запущенном браузере — отказ, файл не тронут")

        let backup = try? NotificationRevoker.block(keys: ["https://win-prize.xyz:443,*", "https://recepty.example:443,*"], prefs: prefsURL,
                                                    backupDir: backups, label: "chrome-Default", browserRunning: false, browserName: "Chrome")
        expect(backup.flatMap { try? Data(contentsOf: $0) } == before, "резервная копия совпадает с прежним файлом")
        let after = BrowserScanner.json(prefsURL)
        let n = after?.dict("profile")?.dict("content_settings")?.dict("exceptions")?.dict("notifications")
        expect((n?["https://win-prize.xyz:443,*"] as? [String: Any])?["setting"] as? Int == 2, "спам-сайт → «запретить»")
        expect((n?["https://mail.google.com:443,*"] as? [String: Any])?["setting"] as? Int == 1, "знакомый сайт не тронут")
        let other = after?.dict("other")
        expect(other?["unicode"] as? String == "Привет / ✓" && (other?["big"] as? NSNumber)?.int64Value == 13319896118022894
               && other?["flag"] as? Bool == true && (other?.dict("nested")?["arr"] as? [Int]) == [1, 2, 3]
               && (other?["num"] as? Double) == 1.5, "остальные настройки сохранены как были")
        let raw = String(decoding: (try? Data(contentsOf: prefsURL)) ?? Data(), as: UTF8.self)
        expect(!raw.contains("\\/"), "слэши не экранируются (как пишет сам Chromium)")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: def.path))?.filter { $0.contains("safetymom") } ?? ["?"]
        expect(leftovers.isEmpty, "временных файлов не осталось")
        expect(BrowserScanner.report(chromeDef, roots: roots, fullDiskAccess: false).notifications.map(\.host) == ["mail.google.com"], "после запрета остался один сайт")
        var notFound = false
        do { try NotificationRevoker.block(keys: ["https://nope:443,*"], prefs: prefsURL, backupDir: backups, label: "x", browserRunning: false, browserName: "Chrome") }
        catch RevokeError.notFound { notFound = true } catch {}
        expect(notFound, "несуществующий сайт → понятная ошибка")

        // Старая Opera: профиль — сама папка данных.
        let opera = roots.appSupport.appendingPathComponent("com.operasoftware.Opera")
        write(["profile": ["content_settings": ["exceptions": ["notifications": ["https://news.top:443,*": ["setting": 1]]]]]], opera.appendingPathComponent("Preferences"))
        let o = BrowserScanner.report(BrowserDef.all.first { $0.id == "opera" }!, roots: roots, fullDiskAccess: false)
        expect(o.profiles.count == 1 && o.notifications.first?.level == .danger, "Opera без папки Default")
    }

    // MARK: Firefox и Safari

    private static func firefoxSafari(_ sandbox: URL) {
        let roots = BrowserRoots(appSupport: sandbox.appendingPathComponent("AS"), safari: sandbox.appendingPathComponent("Safari"))
        let prof = roots.appSupport.appendingPathComponent("Firefox/Profiles/ab12cd.default-release")
        write(["addons": [
            ["id": "uBlock0@raymondhill.net", "type": "extension", "location": "app-profile", "active": true, "userDisabled": false,
             "signedState": 2, "version": "1.60", "defaultLocale": ["name": "uBlock Origin"], "installDate": 1_600_000_000_000,
             "userPermissions": ["permissions": ["storage"], "origins": ["<all_urls>"]]],
            ["id": "helper@unknown", "type": "extension", "location": "app-profile", "active": true, "signedState": 0,
             "defaultLocale": ["name": "Helper"], "userPermissions": ["permissions": ["proxy"], "origins": []]],
            ["id": "newtab@mozilla.org", "type": "extension", "location": "app-profile", "defaultLocale": ["name": "New Tab"]],
            ["id": "formautofill@mozilla.org", "type": "extension", "location": "app-builtin-addons"],
            ["id": "theme@x", "type": "theme", "location": "app-profile"],
        ]], prof.appendingPathComponent("extensions.json"))
        var db: OpaquePointer?
        sqlite3_open(prof.appendingPathComponent("permissions.sqlite").path, &db)
        sqlite3_exec(db, """
            CREATE TABLE moz_perms (id INTEGER PRIMARY KEY, origin TEXT, type TEXT, permission INTEGER, expireType INTEGER, expireTime INTEGER, modificationTime INTEGER);
            INSERT INTO moz_perms (origin, type, permission, modificationTime) VALUES ('https://push-news.online', 'desktop-notification', 1, 1700000000000);
            INSERT INTO moz_perms (origin, type, permission, modificationTime) VALUES ('https://web.whatsapp.com', 'desktop-notification', 2, 1700000000000);
            INSERT INTO moz_perms (origin, type, permission, modificationTime) VALUES ('https://web.whatsapp.com', 'camera', 1, 1700000000000);
            """, nil, nil, nil)
        sqlite3_close(db)
        let f = BrowserScanner.report(BrowserDef.all.first { $0.id == "firefox" }!, roots: roots, fullDiskAccess: false)
        expect(f.extensions.map(\.name).sorted() == ["Helper", "uBlock Origin"], "Firefox: только свои расширения: \(f.extensions.map(\.name))")
        expect(f.extensions.first { $0.name == "Helper" }?.level == .danger, "неподписанное с прокси → красный")
        expect(f.notifications.map(\.host) == ["push-news.online"] && f.notifications[0].level == .danger, "Firefox: разрешённые уведомления")
        expect(!f.canRevoke, "в Firefox SafetyMom не меняет настройки — только подсказывает")

        let pk = """
        +    com.agilebits.onepassword.safari(8.10.1)
        \t            Path = /Applications/1Password for Safari.app/Contents/PlugIns/ext.appex
        \t   Parent Bundle = /Applications/1Password for Safari.app
        \t    Display Name = 1Password for Safari
        -    com.example.adblock(2.0)
        \t   Parent Bundle = /Applications/AdBlock Thing.app
        """
        let s = BrowserScanner.safariExtensions(pk)
        expect(s.map(\.name) == ["1Password for Safari", "AdBlock Thing"] && s[1].enabled == false && s[0].version == "8.10.1",
               "pluginkit: имя, версия, вкл/выкл: \(s.map(\.name))")
        expect(BrowserScanner.safariExtensions("  (no matches)").isEmpty, "pluginkit без расширений")

        let plist = roots.safari.appendingPathComponent("UserNotificationPermissions.plist")
        try? FileManager.default.createDirectory(at: roots.safari, withIntermediateDirectories: true)
        let pd = try! PropertyListSerialization.data(fromPropertyList: ["https://lucky-gift.site": ["Permission": 1], "https://vk.com": ["Permission": 0]], format: .binary, options: 0)
        try! pd.write(to: plist)
        expect(BrowserScanner.safariNotifications(plist).map(\.host) == ["lucky-gift.site"], "Safari: разрешённые уведомления из plist")
        let sNo = BrowserScanner.report(BrowserDef.all.first { $0.id == "safari" }!, roots: roots, fullDiskAccess: false)
        expect(sNo.notifications.isEmpty && !sNo.notificationsReadable && sNo.worstNotification == .unknown && (sNo.notificationsNote ?? "").contains("полного доступа"), "Safari без полного доступа — подсказка, не чтение")
    }
}

// MARK: - Демо-данные (`--demo`, скриншоты)

enum Demo {
    static var checks: [CheckResult] {
        let S = SystemChecks.self
        let now = Date()
        let cur = OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)
        return [
            S.updates(prefs: ["RecommendedUpdates": [["Display Name": "macOS Tahoe 26.7.3", "Display Version": "26.7.3", "Identifier": "MSU_UPDATE_1"]],
                              "LastSuccessfulDate": now.addingTimeInterval(-3600)], current: cur, now: now),
            S.autoUpdates(prefs: [:], commerce: ["AutoUpdate": 1]),
            S.fileVault("FileVault is On.", laptop: true),
            S.firewall("Firewall is disabled. (State = 0)"),
            S.gatekeeper("assessments enabled"),
            S.sip("System Integrity Protection status: enabled."),
            S.timeMachine(prefs: ["AutoBackup": true, "Destinations": [["SnapshotDates": [now.addingTimeInterval(-41 * 86400)]]]],
                          readable: true, destinationInfo: "Name : Backup SSD", now: now),
            S.screenLock("screenLock delay is immediate", screensaverIdle: 300, displaySleep: 10),
            S.autoLogin([:], readable: true),
            S.remote(open: [5900]),
            S.xprotect(version: "5377", updated: now.addingTimeInterval(-6 * 86400), now: now),
        ]
    }

    static var browsers: [BrowserReport] {
        let now = Date()
        func def(_ id: String) -> BrowserDef { BrowserDef.all.first { $0.id == id }! }
        let defaultProfile = String(localized: "Основной")
        func site(_ h: String, _ p: String? = nil, days: Double) -> SiteNotification {
            SiteNotification(key: "https://\(h):443,*", host: h, profile: p ?? defaultProfile, prefs: nil,
                             since: now.addingTimeInterval(-days * 86400), level: BrowserScanner.siteLevel(h))
        }
        func ext(_ id: String, _ name: String, _ v: String, _ flags: [ExtFlag], enabled: Bool = true, days: Double = 300) -> BrowserExtension {
            BrowserExtension(extID: id, name: name, version: v, profile: defaultProfile, enabled: enabled,
                             installed: now.addingTimeInterval(-days * 86400), flags: flags, level: BrowserScanner.extensionLevel(flags))
        }
        let one = [BrowserProfile(dir: URL(fileURLWithPath: "/"), name: defaultProfile)]
        var chrome = BrowserReport(def: def("chrome"), installed: true, running: true, profiles: one)
        chrome.notifications = [site("best-prize-today.xyz", days: 3), site("allow-news-push.top", days: 9),
                                site("recepty-babushki.ru", days: 60), site("mail.google.com", days: 400), site("web.whatsapp.com", days: 200)]
            .sorted { ($0.level, $1.host) > ($1.level, $0.host) }
        chrome.extensions = [ext("a", "Search Manager Pro", "3.1.0", [.allSites, .proxy, .installedByApp, .notStore, .recent], days: 5),
                             ext("b", "Video Downloader HD", "1.4", [.allSites, .notStore], days: 30),
                             ext("c", "AdBlock", "6.55.0", [.allSites]),
                             ext("d", "1Password", "8.12.4", [.allSites, .nativeMessaging]),
                             ext("e", "Google Translate", "2.0.18", [], enabled: false)]
        var safari = BrowserReport(def: def("safari"), installed: true, running: false, profiles: [])
        safari.extensions = [ext("s1", "1Password for Safari", "8.10.1", [])]
        safari.extensionsNote = String(localized: "Включены ли они в самом Safari, видно в Safari → Настройки → Расширения.")
        safari.notifications = [site("lucky-gift.site", "Safari", days: 14)]
        safari.notificationsNote = String(localized: "Снять разрешение: Safari → Настройки → Веб-сайты → Уведомления, или Системные настройки → Уведомления.")
        return [safari, chrome]
    }

    static var network: NetworkReport {
        var n = NetworkReport()
        n.dns = [NetworkScanner.classifyDNS("192.168.1.1"), NetworkScanner.classifyDNS("1.1.1.1")]
        n.hosts = [NetworkScanner.classifyHosts(ip: "0.0.0.0", names: ["ads.example.com"])]
        n.mdm = false
        return n
    }
}

import Foundation
import SQLite3

/// `PrivacyMom --selftest` — всё на временных файлах: поддельная база TCC, поддельные профили браузеров,
/// экранирование имён сетей. Настоящие данные пользователя не трогаются.
enum SelfTest {
    nonisolated(unsafe) private static var ok = true

    private static func expect(_ cond: Bool, _ msg: String) {
        print((cond ? "✓ " : "✗ ") + msg)
        ok = ok && cond
    }

    static func run() -> Never {
        let sandbox = Paths.tmp.appendingPathComponent("privacymom-selftest-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        print("— База разрешений")
        tcc(sandbox)
        print("— Браузеры")
        browsers(sandbox)
        print("— Wi-Fi")
        wifi(sandbox)
        print("— Журнал датчиков")
        sensors(sandbox)

        try? FileManager.default.removeItem(at: sandbox)
        print(ok ? "Всё в порядке" : "ЕСТЬ ОШИБКИ")
        exit(ok ? 0 : 1)
    }

    // MARK: TCC

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            print("SQL: \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
        }
    }

    private static func tcc(_ sandbox: URL) {
        // Схема как в macOS 14–26.
        let modern = sandbox.appendingPathComponent("TCC.db")
        var db: OpaquePointer?
        sqlite3_open(modern.path, &db)
        exec(db, """
            CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
              auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL,
              csreq BLOB, policy_id INTEGER, indirect_object_identifier_type INTEGER,
              indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED', indirect_object_code_identity BLOB,
              flags INTEGER, last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
              pid INTEGER, pid_version INTEGER, boot_uuid TEXT NOT NULL DEFAULT 'UNUSED', last_reminded INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (service, client, client_type, indirect_object_identifier));
            INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified)
              VALUES ('kTCCServiceCamera', 'us.zoom.xos', 0, 2, 2, 1, 1700000000);
            INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified)
              VALUES ('kTCCServiceMicrophone', 'us.zoom.xos', 0, 0, 2, 1, 1700000100);
            INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, last_modified)
              VALUES ('kTCCServiceAppleEvents', 'com.example.robot', 0, 2, 3, 1, 'com.apple.finder', 1700000200);
            INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified)
              VALUES ('kTCCServiceSystemPolicyAllFiles', '/usr/local/bin/backup-tool', 1, 2, 4, 1, 1700000300);
            INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified)
              VALUES ('kTCCServicePhotos', 'com.example.photos', 0, 3, 2, 1, 1700000400);
            INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified)
              VALUES ('kTCCServiceSomethingNew', 'com.example.x', 0, 2, 2, 1, 1700000500);
            """)
        sqlite3_close(db)

        do {
            let rows = try TCCReader.read(modern, source: .user)
            expect(rows.count == 6, "прочитано 6 записей (\(rows.count))")
            let cam = rows.first { $0.service == "kTCCServiceCamera" }
            expect(cam?.auth == .allowed && cam?.client == "us.zoom.xos" && cam?.clientIsPath == false, "камера: разрешено, bundle id")
            expect(cam?.modified == Date(timeIntervalSince1970: 1_700_000_000), "дата изменения прочитана")
            expect(rows.first { $0.service == "kTCCServiceMicrophone" }?.auth == .denied, "микрофон: запрещено")
            let ae = rows.first { $0.service == "kTCCServiceAppleEvents" }
            expect(ae?.target == "com.apple.finder", "автоматизация: цель — Finder")
            expect(cam?.target == nil, "UNUSED в цели → нет цели")
            let fda = rows.first { $0.service == "kTCCServiceSystemPolicyAllFiles" }
            expect(fda?.clientIsPath == true, "программа по пути распознана")
            expect(fda.flatMap(TCCReset.arguments(for:)) == nil, "для программы по пути tccutil не вызывается")
            expect(cam.flatMap(TCCReset.arguments(for:)) == ["reset", "Camera", "us.zoom.xos"], "аргументы tccutil: reset Camera us.zoom.xos")
            expect(rows.first { $0.service == "kTCCServicePhotos" }?.auth == .limited, "фото: ограниченный доступ")
            expect(TCCService.lookup("kTCCServiceSomethingNew").title == "SomethingNew", "неизвестная служба — по сырому имени")
            var snap = TCCSnapshot(); snap.entries = rows
            expect(snap.granted("kTCCServiceCamera") == 1 && snap.granted("kTCCServiceMicrophone") == 0, "счётчики для сводки")
        } catch {
            expect(false, "чтение базы: \(error)")
        }

        // Старая схема: колонка `allowed` вместо `auth_value`, путь с пробелом.
        let oldDir = sandbox.appendingPathComponent("Old Schema", isDirectory: true)
        try? FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let old = oldDir.appendingPathComponent("TCC.db")
        sqlite3_open(old.path, &db)
        exec(db, """
            CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, allowed INTEGER, prompt_count INTEGER);
            INSERT INTO access VALUES ('kTCCServiceAddressBook', 'com.example.old', 0, 1, 1);
            INSERT INTO access VALUES ('kTCCServiceCalendar', 'com.example.old', 0, 0, 1);
            """)
        sqlite3_close(db)
        do {
            let rows = try TCCReader.read(old, source: .system)
            expect(rows.count == 2 && rows.first { $0.service == "kTCCServiceAddressBook" }?.auth == .allowed
                   && rows.first { $0.service == "kTCCServiceCalendar" }?.auth == .denied,
                   "старая схема (allowed) читается")
            expect(rows.allSatisfy { $0.modified == nil }, "нет last_modified — дата пустая")
        } catch {
            expect(false, "старая схема: \(error)")
        }

        let before = (try? Data(contentsOf: modern)) ?? Data()
        _ = try? TCCReader.read(modern, source: .user)
        expect((try? Data(contentsOf: modern)) == before, "чтение не меняет файл базы")
        expect(!FileManager.default.fileExists(atPath: modern.path + "-journal")
               && !FileManager.default.fileExists(atPath: modern.path + "-wal"), "журналы SQLite не созданы")
        expect((try? TCCReader.read(sandbox.appendingPathComponent("missing.db"), source: .user)) == nil, "нет файла — ошибка, а не пустая база")
    }

    // MARK: Браузеры

    private static func touch(_ url: URL, _ bytes: Int = 4096) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(repeating: 7, count: bytes).write(to: url)
    }

    private static func browsers(_ sandbox: URL) {
        let lib = sandbox.appendingPathComponent("Library", isDirectory: true)
        let roots = BrowserRoots(library: lib)
        let chrome = roots.appSupport.appendingPathComponent("Google/Chrome")
        for f in ["Default/History", "Default/History-journal", "Default/Cookies", "Default/Cookies-journal",
                  "Default/Login Data", "Default/Bookmarks", "Default/Preferences", "Default/Web Data",
                  "Profile 1/History", "Profile 1/Network/Cookies", "Profile 1/Bookmarks",
                  "System Profile/History", "Guest Profile/History", "Local State"] {
            touch(chrome.appendingPathComponent(f))
        }
        let chromeCache = roots.caches.appendingPathComponent("Google/Chrome")
        touch(chromeCache.appendingPathComponent("Default/Cache/Cache_Data/data_0"), 100_000)
        touch(chromeCache.appendingPathComponent("Default/Code Cache/js/index"))
        // Старая Opera: всё в корне.
        let opera = roots.appSupport.appendingPathComponent("com.operasoftware.Opera")
        for f in ["History", "Cookies", "Login Data", "Bookmarks"] { touch(opera.appendingPathComponent(f)) }

        let ff = roots.appSupport.appendingPathComponent("Firefox/Profiles/abc.default-release")
        for f in ["places.sqlite", "places.sqlite-wal", "cookies.sqlite", "cookies.sqlite-wal", "logins.json", "key4.db"] {
            touch(ff.appendingPathComponent(f))
        }
        touch(roots.caches.appendingPathComponent("Firefox/Profiles/abc.default-release/cache2/entries/ABC"), 50_000)

        let safari = lib.appendingPathComponent("Safari")
        for f in ["History.db", "History.db-wal", "History.db-shm", "Bookmarks.plist"] { touch(safari.appendingPathComponent(f)) }
        touch(lib.appendingPathComponent("Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"))
        touch(lib.appendingPathComponent("Cookies/HSTS.plist"))

        let def = { (id: String) in BrowserDef.all.first { $0.id == id }! }
        func rel(_ t: BrowserTarget) -> Set<String> {
            Set(t.files.map { String($0.url.path.dropFirst(lib.path.count + 1)) })
        }

        let c = BrowserScanner.report(def("chrome"), roots: roots, fullDiskAccess: false, measure: true)
        expect(c.profiles == ["Default", "Profile 1"], "Chrome: профили Default и Profile 1 (служебные пропущены)")
        expect(rel(c.target(.history)) == ["Application Support/Google/Chrome/Default/History",
                                           "Application Support/Google/Chrome/Default/History-journal",
                                           "Application Support/Google/Chrome/Profile 1/History"], "Chrome: история — только History*")
        expect(rel(c.target(.cookies)) == ["Application Support/Google/Chrome/Default/Cookies",
                                           "Application Support/Google/Chrome/Default/Cookies-journal",
                                           "Application Support/Google/Chrome/Profile 1/Network/Cookies"], "Chrome: cookies — Cookies* и Network/Cookies")
        expect(rel(c.target(.cache)) == ["Caches/Google/Chrome/Default/Cache", "Caches/Google/Chrome/Default/Code Cache"], "Chrome: кэш — содержимое ~/Library/Caches/…/Default")
        expect(c.target(.cache).size >= 100_000, "Chrome: размер кэша посчитан (\(Fmt.bytes(c.target(.cache).size)))")

        let o = BrowserScanner.report(def("opera"), roots: roots, fullDiskAccess: false, measure: false)
        expect(rel(o.target(.history)) == ["Application Support/com.operasoftware.Opera/History"], "Opera без профилей: история в корне")

        let f = BrowserScanner.report(def("firefox"), roots: roots, fullDiskAccess: false, measure: false)
        expect(f.target(.history).files.isEmpty && f.target(.history).unavailable != nil, "Firefox: историю не предлагаем (places.sqlite = закладки)")
        expect(rel(f.target(.cookies)) == ["Application Support/Firefox/Profiles/abc.default-release/cookies.sqlite",
                                           "Application Support/Firefox/Profiles/abc.default-release/cookies.sqlite-wal"], "Firefox: cookies.sqlite*")
        expect(rel(f.target(.cache)) == ["Caches/Firefox/Profiles/abc.default-release/cache2/entries"], "Firefox: кэш cache2")

        let sNo = BrowserScanner.report(def("safari"), roots: roots, fullDiskAccess: false, measure: false)
        expect(BrowserDataKind.allCases.allSatisfy { sNo.target($0).unavailable == "нужен доступ" && sNo.target($0).files.isEmpty },
               "Safari без полного доступа: «нужен доступ», файлы не трогаем")
        let s = BrowserScanner.report(def("safari"), roots: roots, fullDiskAccess: true, measure: false)
        expect(rel(s.target(.history)) == ["Safari/History.db", "Safari/History.db-wal", "Safari/History.db-shm"], "Safari: History.db* (без Bookmarks.plist)")
        expect(rel(s.target(.cookies)) == ["Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"], "Safari: Cookies.binarycookies (HSTS.plist не трогаем)")

        let all = [c, o, f, s].flatMap { r in BrowserDataKind.allCases.flatMap { r.target($0).files } }
        expect(!all.contains { BrowserScanner.protectedNames.contains($0.url.lastPathComponent) || $0.url.lastPathComponent.hasPrefix("Bookmarks") },
               "ни пароли, ни закладки, ни places.sqlite в цели не попали")

        // Очистка: «Корзина» подменена папкой в песочнице.
        let trash = sandbox.appendingPathComponent("FakeTrash", isDirectory: true)
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var n = 0
        let fakeTrash: (URL) throws -> Void = { u in
            n += 1
            try FileManager.default.moveItem(at: u, to: trash.appendingPathComponent("\(n)-\(u.lastPathComponent)"))
        }
        let hist = BrowserScanner.clean(def("chrome"), c.target(.history), checkRunning: false, trash: fakeTrash)
        expect(hist.removed == 3 && hist.failures.isEmpty, "история Chrome убрана (\(hist.removed))")
        expect(((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).count == 3, "история ушла в Корзину, а не удалена")
        let fm = FileManager.default
        expect(fm.fileExists(atPath: chrome.appendingPathComponent("Default/Login Data").path)
               && fm.fileExists(atPath: chrome.appendingPathComponent("Default/Bookmarks").path)
               && fm.fileExists(atPath: chrome.appendingPathComponent("Default/Cookies").path), "пароли, закладки и cookies на месте")
        let cache = BrowserScanner.clean(def("chrome"), c.target(.cache), checkRunning: false, trash: fakeTrash)
        expect(cache.removed == 2 && !fm.fileExists(atPath: chromeCache.appendingPathComponent("Default/Cache").path)
               && fm.fileExists(atPath: chromeCache.appendingPathComponent("Default").path), "кэш удалён, папка профиля осталась")

        // Подсунутые небезопасные цели отклоняются.
        let outside = sandbox.appendingPathComponent("keep.txt"); touch(outside)
        var evil = BrowserTarget(kind: .cache)
        evil.files = [CleanFile(url: outside, root: chrome, size: 0),
                      CleanFile(url: chrome.appendingPathComponent("Default/Login Data"), root: chrome, size: 0),
                      CleanFile(url: chrome, root: chrome, size: 0),
                      CleanFile(url: Paths.home.appendingPathComponent("Documents"), root: Paths.home, size: 0)]
        let ev = BrowserScanner.clean(def("chrome"), evil, checkRunning: false, trash: fakeTrash)
        expect(ev.removed == 0 && ev.failures.count == 4, "4 небезопасные цели отклонены")
        expect(fm.fileExists(atPath: outside.path) && fm.fileExists(atPath: chrome.appendingPathComponent("Default/Login Data").path),
               "файлы вне папки браузера и пароли не тронуты")
    }

    // MARK: Wi-Fi

    private static func wifi(_ sandbox: URL) {
        let ports = """
            Hardware Port: Ethernet Adapter (en4)
            Device: en4
            Ethernet Address: 00:00:00:00:00:01

            Hardware Port: Wi-Fi
            Device: en0
            Ethernet Address: 00:00:00:00:00:02
            """
        expect(WifiNetworks.parseDevice(ports) == "en0", "устройство Wi-Fi: en0")
        let pref = "Preferred networks on en0:\n\tДом 5G\n\tit's \"cafe\"\n\t  spaced \n"
        expect(WifiNetworks.parsePreferred(pref) == ["Дом 5G", "it's \"cafe\"", "  spaced "], "список сетей разобран (пробелы сохранены)")
        let prof = "Wi-Fi:\n      Interfaces:\n        en0:\n          Current Network Information:\n            93_Plus:\n              PHY Mode: 802.11n\n"
        expect(WifiNetworks.parseCurrent(prof) == "93_Plus", "текущая сеть из system_profiler")
        expect(WifiNetworks.parseCurrent("Wi-Fi:\n  Status: Off\n") == nil, "нет подключения — нет текущей сети")

        // Имя сети не попадает в текст AppleScript и доходит до программы байт в байт.
        let sentinel = sandbox.appendingPathComponent("pwned")
        let nasty = [
            "it's \"me\"", "$(touch \(sentinel.path))", "`touch \(sentinel.path)`", "a; touch \(sentinel.path)",
            "\" & (do shell script \"touch \(sentinel.path)\") & \"", "back\\slash \\\" end", "Кафе «Уют» 5G",
            "  spaced  ", "-n", "100% & <ok> | 'x'",
        ]
        let src = Shell.doShellScriptSource(argCount: 2, admin: true).joined(separator: "\n")
        expect(!nasty.contains { src.contains($0) } && src.contains("quoted form of (item 3 of argv)")
               && src.contains("with administrator privileges"), "текст скрипта не содержит имени сети")
        for ssid in nasty {
            let r = Shell.runViaAppleScript("/usr/bin/printf", ["[%s]", ssid], admin: false)
            expect(r.ok && r.output == "[\(ssid)]", "экранирование: \(ssid)")
        }
        expect(!FileManager.default.fileExists(atPath: sentinel.path), "ни одна команда из имени сети не выполнилась")
    }

    // MARK: Датчики

    private static func sensors(_ sandbox: URL) {
        let a = SensorDevice(kind: .camera, uid: "cam1", name: "FaceTime HD", running: false)
        let m = SensorDevice(kind: .microphone, uid: "mic1", name: "MacBook Pro Microphone", running: false)
        var a2 = a; a2.running = true
        let t = Date()
        let on = SensorDiff.events(old: [a, m], new: [a2, m], at: t)
        expect(on.count == 1 && on[0].on && on[0].kind == .camera, "камера включилась — одно событие")
        expect(SensorDiff.events(old: [a2, m], new: [a2, m], at: t).isEmpty, "без изменений — нет событий")
        let gone = SensorDiff.events(old: [a2, m], new: [m], at: t)
        expect(gone.count == 1 && !gone[0].on, "включённое устройство отключили — событие «выключено»")

        let log = SensorLog(url: sandbox.appendingPathComponent("log/sensors.jsonl"))
        log.append(SensorEvent(t: t.addingTimeInterval(-10 * 86_400), kind: .camera, device: "old", on: true))
        log.append(on[0])
        log.append(gone[0])
        let loaded = log.load(now: t)
        expect(loaded.count == 2 && loaded.allSatisfy { $0.device == "FaceTime HD" }, "журнал: показаны только последние 7 дней")
        let lines = (try? String(contentsOf: log.url, encoding: .utf8))?.split(separator: "\n").count
        expect(lines == 2, "журнал: старые строки вычищены из файла")
    }
}

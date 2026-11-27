import Foundation

// MARK: - Самопроверка (`swift run HelpMom --selftest`)
// Только временная папка и выдуманные данные: ни звонков, ни сообщений, ни общего буфера обмена.

enum SelfTest {
    static func run() -> Bool {
        var ok = true
        func expect(_ cond: Bool, _ msg: String) { print((cond ? "✓ " : "✗ ") + msg); ok = ok && cond }

        // Отчёт и «светофор»
        let r = DemoData.report()
        let text = r.text(includeSerial: false)
        expect(text.contains("MacBook Air") && text.contains("macOS 15.6 Sequoia"), "отчёт: модель и версия macOS")
        expect(!text.contains("C02XK1ABJG5J"), "серийный номер не попадает в отчёт без галочки")
        expect(r.text(includeSerial: true).contains("C02XK1ABJG5J"), "серийный номер есть с галочкой")
        expect(r.findings.contains { $0.id == "uptime" && $0.level == .warn }, "12 дней без перезагрузки — жёлтый")
        expect(r.findings.contains { $0.id == "disk" && $0.level == .warn }, "18 ГБ свободно — жёлтый")
        expect(r.findings.contains { $0.id == "crash" }, "частые сбои одного приложения замечены")
        expect(r.overall == .warn && r.headline == "Есть на что посмотреть", "итог — «есть на что посмотреть»")
        expect(text.contains("Safari — вылетало: 3 раза"), "сбои сгруппированы по приложению")

        var good = r
        good.bootTime = good.collectedAt.addingTimeInterval(-3600)
        good.diskFree = 200_000_000_000
        good.crashes = []
        good.updates = []
        expect(good.overall == .ok && good.findings.isEmpty, "здоровый Mac — «всё в порядке»")
        var bad = good
        bad.diskFree = 4_000_000_000
        bad.network = NetworkSummary(connected: true, interface: "Wi-Fi", localIP: nil, internet: false)
        expect(bad.overall == .bad && bad.findings.first?.level == .bad, "нет места и интернета — красный")
        expect(MemoryPressure(sysctl: 4) == .critical && MemoryPressure(sysctl: 1) == .normal, "давление памяти из sysctl")

        // Имена отчётов о сбоях — только из имён файлов
        let p1 = CrashReports.parse(fileName: "Safari-2026-11-20-101010.ips")
        expect(p1?.app == "Safari" && p1?.kind == .crash, "Safari-….ips → сбой Safari")
        expect(CrashReports.parse(fileName: "Google Chrome Helper (Renderer)-2026-11-20-101010.ips")?.app == "Google Chrome Helper (Renderer)",
               "имя с пробелами и скобками")
        expect(CrashReports.parse(fileName: "Code Helper_2026-11-24-104502_MacBook.diag") == nil, ".diag пропускается")
        expect(CrashReports.parse(fileName: "JetsamEvent-2026-11-20-101010.ips")?.kind == .memory, "JetsamEvent — нехватка памяти")
        expect(CrashReports.parse(fileName: "panic-full-2026-11-20-101010.panic")?.kind == .panic, "panic — перезагрузка из-за сбоя")
        expect(CrashReports.parse(fileName: ".contents.panic") == nil, "скрытые файлы пропускаются")
        expect(CrashReports.parse(fileName: "ExcUserFault_Finder-2026-11-20-101010.ips") == nil, "ExcUserFault пропускается")
        expect(CrashReports.parse(fileName: "Mail-2026-11-20-101010.hang")?.kind == .hang, ".hang — зависание")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("helpmom-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let crashDir = tmp.appendingPathComponent("DiagnosticReports")
        try? FileManager.default.createDirectory(at: crashDir.appendingPathComponent("Retired"), withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let recent = f.string(from: Date().addingTimeInterval(-86_400)), old = f.string(from: Date().addingTimeInterval(-30 * 86_400))
        for name in ["Safari-\(recent).ips", "Safari-\(old).ips", "Notes-\(recent).ips", "x_\(recent)_host.diag", ".hidden.ips"] {
            FileManager.default.createFile(atPath: crashDir.appendingPathComponent(name).path, contents: Data("secret".utf8))
        }
        FileManager.default.createFile(atPath: crashDir.appendingPathComponent("Retired/Notes-\(recent).ips").path, contents: nil)
        let found = CrashReports.scan(dirs: [crashDir, crashDir.appendingPathComponent("Retired")], since: Date().addingTimeInterval(-7 * 86_400))
        expect(found.count == 2 && Set(found.map(\.app)) == ["Safari", "Notes"], "сбои за 7 дней: старые и служебные отброшены, дубли из Retired — один раз")

        // Процессы: помощники складываются в приложение
        let ps = """
          45.0 102400 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
          10,5  51200 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
           3.0   2048 /usr/libexec/trustd
           0.0     10 ps
        """
        let top = ProcessParser.top(psOutput: ps, limit: 5)
        expect(top.first?.name == "Google Chrome" && abs((top.first?.cpu ?? 0) - 55.5) < 0.01, "помощники Chrome сложены в «Google Chrome»")
        expect(top.count == 2 && top.last?.name == "trustd", "ps в списке не показывается")

        // Ссылки
        expect(Contact.phone("+7 (999) 123-45-67") == "+79991234567", "телефон нормализуется")
        expect(Contact.phone("позвони мне") == nil, "не номер — nil")
        expect(Contact.email("masha@example.com") == "masha@example.com" && Contact.email("masha@ex ample.com") == nil, "e-mail проверяется")
        expect(Contact.telegram("@masha_k") == "masha_k" && Contact.telegram("https://t.me/masha_k") == "masha_k", "Telegram: @ и t.me/ срезаются")
        expect(Contact.telegram("masha k") == nil && Contact.telegram("ma&x=1") == nil, "Telegram: недопустимое имя — nil")
        expect(Contact.faceTime("+79991234567", audio: false)?.absoluteString == "facetime://+79991234567", "ссылка FaceTime")
        expect(Contact.faceTime("a b@x.com", audio: true)?.absoluteString == "facetime-audio://a%20b@x.com", "FaceTime: пробел экранируется")
        expect(Contact.telegramApp("masha_k")?.absoluteString == "tg://resolve?domain=masha_k", "ссылка Telegram")
        let h = Helper(name: "Маша", phone: "", email: "masha@example.com", telegram: "@masha_k")
        expect(h.appleHandle == "masha@example.com" && h.initials == "М", "без телефона — FaceTime по e-mail")

        // Хранение помощников
        let store = HelperStore(dir: tmp.appendingPathComponent("HelpMom"))
        do {
            try store.save(DemoData.helpers)
            let back = store.load()
            expect(back == DemoData.helpers, "помощники сохраняются и читаются")
            let perms = (try? FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int) ?? 0
            let dperms = (try? FileManager.default.attributesOfItem(atPath: store.dir.path)[.posixPermissions] as? Int) ?? 0
            expect(perms == 0o600 && dperms == 0o700, "права: файл 0600, папка 0700")
        } catch {
            expect(false, "сохранение помощников: \(error)")
        }

        print(ok ? "Все проверки пройдены" : "Есть ошибки")
        return ok
    }
}

// MARK: - Демо-данные (`--demo`, скриншоты, самопроверка)

enum DemoData {
    static let helpers = [
        Helper(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Маша", phone: "+7 999 123-45-67",
               email: "masha@example.com", telegram: "@masha_k"),
        Helper(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Дима", phone: "",
               email: "dima@example.com", telegram: ""),
    ]

    static func report(now: Date = Date()) -> SystemReport {
        var r = SystemReport()
        r.collectedAt = now
        r.computerName = "MacBook Air — Мама"
        r.userName = "Елена Петровна"
        r.modelName = "MacBook Air (13-inch, M2, 2022)"
        r.modelID = "Mac14,2"
        r.chip = "Apple M2"
        r.memory = 8 * 1_073_741_824
        r.serial = "C02XK1ABJG5J"
        r.osVersion = "15.6"
        r.osBuild = "24G84"
        r.bootTime = now.addingTimeInterval(-12 * 86_400 - 3 * 3600)
        r.diskTotal = 245_000_000_000
        r.diskFree = 18_400_000_000
        r.memoryPressure = .normal
        r.swapUsed = 1_200_000_000
        r.battery = BatterySummary(percent: 76, charging: false, pluggedIn: false, cycles: 312, health: 88)
        r.network = NetworkSummary(connected: true, interface: "Wi-Fi", localIP: "192.168.1.23", internet: true)
        r.topProcesses = [
            ProcessUsage(name: "Google Chrome", cpu: 46, memory: 2_300_000_000),
            ProcessUsage(name: "WindowServer", cpu: 12, memory: 410_000_000),
            ProcessUsage(name: "Zoom", cpu: 8, memory: 520_000_000),
            ProcessUsage(name: "Почта", cpu: 3, memory: 260_000_000),
            ProcessUsage(name: "Фото", cpu: 1, memory: 340_000_000),
        ]
        r.crashes = [
            CrashEvent(app: "Safari", date: now.addingTimeInterval(-3600 * 5), kind: .crash),
            CrashEvent(app: "Safari", date: now.addingTimeInterval(-86_400 * 2), kind: .crash),
            CrashEvent(app: "Safari", date: now.addingTimeInterval(-86_400 * 4), kind: .crash),
            CrashEvent(app: "Zoom", date: now.addingTimeInterval(-86_400 * 3), kind: .hang),
        ]
        r.updates = ["macOS Sequoia 15.7", "Safari 26.1"]
        return r
    }
}

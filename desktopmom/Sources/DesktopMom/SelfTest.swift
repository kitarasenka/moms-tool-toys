import Foundation

/// `--selftest`: всё во временной песочнице (её «домашняя папка», «Рабочий стол», «Загрузки», «Корзина»).
/// Настоящие папки, Корзина и настройка снимков экрана не трогаются.
enum SelfTest {
    nonisolated(unsafe) private static var failed = 0

    private static func expect(_ ok: Bool, _ what: String) {
        print((ok ? "  ✓ " : "  ✗ ") + what)
        if !ok { failed += 1 }
    }

    private static func write(_ url: URL, _ text: String = "x") {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    private static func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    private static func setScreenCapture(_ url: URL) {
        let data = try! PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        _ = data.withUnsafeBytes { setxattr(url.path, Classifier.screenCaptureAttr, $0.baseAddress, data.count, 0, 0) }
    }

    static func run() {
        let fm = FileManager.default
        let box = fm.temporaryDirectory.appendingPathComponent("desktopmom-selftest-\(UUID().uuidString)", isDirectory: true)
        let outside = fm.temporaryDirectory.appendingPathComponent("desktopmom-outside-\(UUID().uuidString)", isDirectory: true)
        let home = box.appendingPathComponent("home", isDirectory: true)
        let roots = Roots(home: home, desktop: home.appendingPathComponent("Desktop", isDirectory: true),
                          downloads: home.appendingPathComponent("Downloads", isDirectory: true))
        for d in [roots.desktop, roots.downloads, outside] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }

        print("Распознавание снимков экрана")
        expect(Classifier.looksLikeScreenshot(name: "Снимок экрана 2026-11-02 в 10.11.12.png"), "«Снимок экрана … .png»")
        expect(Classifier.looksLikeScreenshot(name: "Screenshot 2024-01-01 at 10.00.00.png"), "«Screenshot … .png»")
        expect(Classifier.looksLikeScreenshot(name: "Запись экрана 2026-11-02 в 10.11.12.mov"), "«Запись экрана … .mov»")
        expect(!Classifier.looksLikeScreenshot(name: "Screenshot ideas.docx"), "«Screenshot ideas.docx» — не снимок")
        expect(!Classifier.looksLikeScreenshot(name: "отпуск.jpg"), "обычное фото — не снимок")
        // Имена, которые macOS даёт снимкам и записям экрана на других языках
        for n in ["Screen Recording 2024-01-01 at 10.00.00.mov", "Bildschirmfoto 2024-01-01 um 10.00.00.png",
                  "Bildschirmaufnahme 2024-01-01 um 10.00.00.mov", "Capture d’écran 2024-01-01 à 10.00.00.png",
                  "Capture d'écran 2024-01-01 à 10.00.00.png", "Enregistrement de l’écran 2024-01-01 à 10.00.00.mov",
                  "截屏2024-01-01 10.00.00.png", "屏幕录制2024-01-01 10.00.00.mov",
                  "لقطة شاشة 2024-01-01 في 10.00.00.png", "تسجيل الشاشة 2024-01-01 في 10.00.00.mov"] {
            expect(Classifier.looksLikeScreenshot(name: n), "«\(n)»")
        }
        expect(!Classifier.looksLikeScreenshot(name: "Bildschirmfoto Ideen.pages"), "«Bildschirmfoto Ideen.pages» — не снимок")
        let tagged = roots.desktop.appendingPathComponent("IMG_0001.png")
        let plain = roots.desktop.appendingPathComponent("IMG_0002.png")
        write(tagged); write(plain)
        setScreenCapture(tagged)
        expect(Classifier.isScreenCapture(tagged, spotlight: false), "метка kMDItemIsScreenCapture читается из xattr")
        expect(!Classifier.isScreenCapture(plain, spotlight: false), "без метки — не снимок")

        print("Обход Рабочего стола")
        write(roots.desktop.appendingPathComponent("Снимок экрана 2026-11-02 в 10.11.12.png"))
        write(roots.desktop.appendingPathComponent("Отчёт.pdf"))
        write(roots.desktop.appendingPathComponent(".DS_Store"))
        write(roots.desktop.appendingPathComponent(".localized"))
        write(roots.desktop.appendingPathComponent("Папка/внутри.png"))
        write(roots.desktop.appendingPathComponent("Калькулятор.app/Contents/Info.plist"))
        write(outside.appendingPathComponent("secret.txt"), "секрет")
        try? fm.createSymbolicLink(at: roots.desktop.appendingPathComponent("ссылка"), withDestinationURL: outside)
        let scanned = (try? Scanner.scan(roots.desktop, spotlight: false)) ?? []
        let byName = Dictionary(uniqueKeysWithValues: scanned.map { ($0.name, $0) })
        expect(byName["IMG_0001.png"]?.group == .screenshots && byName["IMG_0002.png"]?.group == .images, "снимок по метке, фото — в картинках")
        expect(byName["Снимок экрана 2026-11-02 в 10.11.12.png"]?.group == .screenshots, "снимок по имени")
        expect(byName["Отчёт.pdf"]?.group == .documents, "PDF — документ")
        expect(byName[".DS_Store"] == nil && byName[".localized"] == nil, "скрытые файлы и .localized не показываются")
        expect(byName["внутри.png"] == nil && byName["Папка"]?.group == .folders, "в подпапки не заходим, папка — одна строка")
        expect(byName["Калькулятор.app"]?.group == .installers && byName["Калькулятор.app"]?.isFolder == false, ".app — один объект")
        expect(byName["ссылка"]?.isSymlink == true && byName["ссылка"]?.group == .other, "ссылка не раскрывается")

        print("Раскладка по месяцам")
        var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 5; comps.hour = 12
        let nov = Calendar(identifier: .gregorian).date(from: comps)!
        expect(Organizer.monthFolder(for: nov) == "2026-11 ноябрь", "папка месяца «\(Organizer.monthFolder(for: nov))»")
        expect(Organizer.monthFolder(for: nov, locale: Locale(identifier: "en_US")) == "2026-11 November", "по-английски — «2026-11 November»")
        expect(Organizer.monthFolder(for: nov, locale: Locale(identifier: "de_DE")) == "2026-11 November", "по-немецки — «2026-11 November»")
        expect(Organizer.monthFolder(for: nov, locale: Locale(identifier: "ar_SA")).hasPrefix("2026-11 "),
               "по-арабски номер месяца латинскими цифрами: «\(Organizer.monthFolder(for: nov, locale: Locale(identifier: "ar_SA")))»")
        expect(roots.defaultScreenshots.lastPathComponent == "Снимки экрана", "папка снимков по умолчанию — «Снимки экрана»")
        let base = roots.defaultScreenshots.appendingPathComponent("2026-11 ноябрь", isDirectory: true)
        write(base.appendingPathComponent("IMG_0001.png"), "старый")
        write(base.appendingPathComponent("IMG_0001 2.png"), "старый 2")
        expect(Organizer.uniqueURL(for: "IMG_0001.png", in: base).lastPathComponent == "IMG_0001 3.png", "занятое имя → «IMG_0001 3.png»")
        expect(Organizer.uniqueURL(for: "Папка", in: roots.desktop).lastPathComponent == "Папка 2", "папка → «Папка 2»")
        var r = Organizer.move([(tagged, base)], root: roots.desktop, home: home)
        let landed = base.appendingPathComponent("IMG_0001 3.png")
        expect(r.failures.isEmpty && r.done.first?.to?.lastPathComponent == "IMG_0001 3.png", "снимок переложен под новым именем")
        expect(!Paths.exists(tagged) && read(landed) == "x" && read(base.appendingPathComponent("IMG_0001.png")) == "старый",
               "ничего не перезаписано, со стола исчез")
        r = Organizer.move([(roots.desktop.appendingPathComponent("ссылка"), base)], root: roots.desktop, home: home)
        expect(r.failures.isEmpty && read(outside.appendingPathComponent("secret.txt")) == "секрет", "ссылка переезжает как ссылка, цель цела")

        print("Смена языка не плодит папки")
        expect(Organizer.monthDir(in: roots.defaultScreenshots, for: nov) == base, "есть «2026-11 ноябрь» — кладём в неё")
        comps.month = 12
        let dec = Calendar(identifier: .gregorian).date(from: comps)!
        expect(Organizer.monthDir(in: roots.defaultScreenshots, for: dec).lastPathComponent == Organizer.monthFolder(for: dec),
               "нового месяца ещё нет — папка с названием на языке приложения")
        let pics = home.appendingPathComponent("Pictures", isDirectory: true)
        try? fm.createDirectory(at: pics.appendingPathComponent("Снимки экрана"), withIntermediateDirectories: true)
        expect(Paths.folder(in: pics, localized: "Screenshots", russian: "Снимки экрана").lastPathComponent == "Снимки экрана",
               "английский DesktopMom продолжает русскую папку, если она уже есть")
        expect(Paths.folder(in: home, localized: "Screenshots", russian: "Снимки экрана").lastPathComponent == "Screenshots",
               "русской нет — папка на языке приложения")

        print("Отказы")
        let viaDots = roots.desktop.appendingPathComponent("../outside.txt")
        write(home.appendingPathComponent("outside.txt"))
        r = Organizer.move([(viaDots, base)], root: roots.desktop, home: home)
        expect(r.done.isEmpty && Paths.exists(home.appendingPathComponent("outside.txt")), "«Desktop/../файл» — отказ")
        try? fm.createSymbolicLink(at: roots.desktop.appendingPathComponent("наружу"), withDestinationURL: outside)
        r = Organizer.move([(roots.desktop.appendingPathComponent("наружу/secret.txt"), base)], root: roots.desktop, home: home)
        expect(r.done.isEmpty && read(outside.appendingPathComponent("secret.txt")) == "секрет", "через ссылку-папку наружу — отказ")
        r = Organizer.move([(roots.desktop.appendingPathComponent("Отчёт.pdf"), outside)], root: roots.desktop, home: home)
        expect(r.done.isEmpty && Paths.exists(roots.desktop.appendingPathComponent("Отчёт.pdf")), "назначение вне домашней папки — отказ")
        r = Organizer.move([(roots.desktop.appendingPathComponent("Папка"), roots.desktop.appendingPathComponent("Папка/Вложенная"))],
                           root: roots.desktop, home: home)
        expect(r.done.isEmpty, "папку в саму себя — отказ")
        r = Organizer.move([(roots.desktop.appendingPathComponent(".DS_Store"), base)], root: roots.desktop, home: home)
        expect(r.done.isEmpty, "скрытый файл — отказ")
        r = Organizer.move([(roots.desktop.appendingPathComponent("Папка/внутри.png"), base)], root: roots.desktop, home: home)
        expect(r.done.isEmpty, "файл из подпапки — отказ (только верхний уровень)")

        print("Загрузки")
        let apps = box.appendingPathComponent("Applications", isDirectory: true)
        for n in ["Google Chrome.app", "zoom.us.app", "Telegram.app", "VLC.app"] {
            write(apps.appendingPathComponent(n).appendingPathComponent("Contents/Info.plist"))
        }
        let installed = Installed.list(in: [apps])
        expect(Installed.match("googlechrome.dmg", in: installed)?.name == "Google Chrome", "googlechrome.dmg → Google Chrome")
        expect(Installed.match("zoomusInstallerFull.pkg", in: installed)?.name == "zoom.us", "zoomusInstallerFull.pkg → zoom.us")
        expect(Installed.match("Telegram-macOS-11.2.dmg", in: installed)?.name == "Telegram", "Telegram-macOS-11.2.dmg → Telegram")
        expect(Installed.match("vlc-3.0.20-universal.dmg", in: installed)?.name == "VLC", "vlc-3.0.20-universal.dmg → VLC")
        expect(Installed.match("Skype-8.99.dmg", in: installed) == nil, "Skype не установлен — без отметки")
        write(roots.downloads.appendingPathComponent("googlechrome.dmg"))
        write(roots.downloads.appendingPathComponent("Выписка.pdf"))
        let dl = (try? Scanner.scan(roots.downloads, installed: installed, spotlight: false)) ?? []
        expect(dl.first { $0.name == "googlechrome.dmg" }?.installedMatch == "Google Chrome"
               && dl.first { $0.name == "Выписка.pdf" }?.installedMatch == nil, "скан Загрузок отмечает установленное")
        let now = Date.now
        let old = Entry(url: roots.downloads.appendingPathComponent("a"), group: .other, size: 1,
                        created: now.addingTimeInterval(-400 * 86_400), modified: now.addingTimeInterval(-200 * 86_400),
                        lastUsed: nil, added: now.addingTimeInterval(-200 * 86_400))
        var opened = old
        opened.lastUsed = now.addingTimeInterval(-5 * 86_400)
        expect(old.isOld(days: 90, now: now) && !old.isOld(days: 365, now: now), "200 дней: старый при 90, не старый при 365")
        expect(!opened.isOld(days: 90, now: now), "открывали 5 дней назад — не старый")

        print("Корзина (папка в песочнице)")
        let trashDir = box.appendingPathComponent("Trash", isDirectory: true)
        let chrome = roots.downloads.appendingPathComponent("googlechrome.dmg")
        let tr = Organizer.trash([chrome, home.appendingPathComponent("outside.txt"),
                                  roots.downloads.appendingPathComponent("../outside.txt")],
                                 root: roots.downloads, trasher: .folder(trashDir))
        expect(tr.done.count == 1 && !Paths.exists(chrome) && tr.done[0].to.map(Paths.exists) == true, "в Корзину ушло только выбранное из Загрузок")
        expect(tr.failures.count == 2 && Paths.exists(home.appendingPathComponent("outside.txt")), "файлы вне Загрузок — отказ")

        print("Журнал")
        let logURL = home.appendingPathComponent("Library/Application Support/DesktopMom/log.json")
        let move = LogEntry(date: now, action: .moved, from: tagged.path, to: landed.path)
        let trashed = LogEntry(date: now, action: .trashed, from: chrome.path, to: tr.done.first?.to?.path)
        MainActor.assumeIsolated {
            let j = Journal(url: logURL)
            j.add([move, trashed])
        }
        let perms = { (p: String) in ((try? fm.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue }
        expect(perms(logURL.path) == 0o600 && perms(logURL.deletingLastPathComponent().path) == 0o700, "log.json 0600, папка 0700")
        let reloaded = MainActor.assumeIsolated { Journal(url: logURL).entries }
        expect(reloaded.count == 2 && reloaded[0].from == tagged.path, "журнал читается обратно")
        expect(Journal.canUndo(move, home: home), "перенос можно вернуть")
        write(tagged, "самозванец")
        expect(!Journal.canUndo(move, home: home), "место занято — вернуть нельзя")
        try? fm.removeItem(at: tagged)
        do { try Journal.undo(move, home: home) } catch { print("    \(error)") }
        expect(read(tagged) == "x" && !Paths.exists(landed), "«Вернуть» кладёт снимок обратно на стол")
        expect(!Journal.canUndo(move, home: home), "повторно вернуть нельзя — файла на новом месте нет")
        do { try Journal.undo(trashed, home: home) } catch { print("    \(error)") }
        expect(Paths.exists(chrome), "из «Корзины» тоже возвращается")
        var undone = move
        undone.undone = true
        expect(!Journal.canUndo(undone, home: home), "уже возвращённое — без кнопки")

        try? fm.removeItem(at: box)
        try? fm.removeItem(at: outside)
        print(failed == 0 ? "Всё в порядке" : "ЕСТЬ ОШИБКИ: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}

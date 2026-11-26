import AppKit
import Foundation

/// Образцы для `--demo` (скриншоты, показ): только во временной папке и в памяти.
enum DemoData {
    static func fill(_ h: History) {
        let now = Date.now
        func add(_ kind: ClipKind, _ text: String?, ago: TimeInterval, app: (String, String)?,
                 pinned: Bool = false, files: [String]? = nil, png: Data? = nil) {
            var it = ClipItem(kind: kind, text: text, files: files, bytes: text?.utf8.count ?? png?.count ?? 0,
                              digest: UUID().uuidString, created: now - ago, date: now - ago,
                              sourceID: app?.0, sourceName: app?.1)
            it.pinned = pinned
            if let png, let rep = NSBitmapImageRep(data: png) {
                it.image = "\(it.id.uuidString).png"
                it.thumb = "\(it.id.uuidString)-thumb.png"
                it.pixelWidth = rep.pixelsWide
                it.pixelHeight = rep.pixelsHigh
                try? h.store.writeImage(png, name: it.image!)
                if let t = Thumbnail.make(from: png) { try? h.store.writeImage(t, name: it.thumb!) }
            }
            h.insertRaw(it)
        }
        let safari = ("com.apple.Safari", "Safari"), notes = ("com.apple.Notes", "Заметки")
        let mail = ("com.apple.mail", "Почта"), finder = ("com.apple.finder", "Finder")
        let messages = ("com.apple.MobileSMS", "Сообщения"), pages = ("com.apple.TextEdit", "TextEdit")
        add(.link, "https://www.gosuslugi.ru/help/faq/passport", ago: 20, app: safari)
        add(.text, "Купить: молоко, гречку, яблоки «Антоновка», батарейки AA для пульта", ago: 150, app: notes)
        add(.image, nil, ago: 600, app: ("com.apple.Preview", "Просмотр"), png: sampleImage())
        add(.text, "Здравствуйте! Подтверждаю запись к терапевту на четверг, 10:30. Номер полиса: 7700 1234 5678 9012.",
            ago: 1_800, app: mail)
        add(.files, "/Users/Shared/Фото с дачи.heic\n/Users/Shared/Рецепт пирога.pdf", ago: 3_600, app: finder,
            files: ["/Users/Shared/Фото с дачи.heic", "/Users/Shared/Рецепт пирога.pdf"])
        add(.text, "Код от домофона: 45К7890", ago: 7_200, app: messages, pinned: true)
        add(.link, "https://yandex.ru/maps/-/CDqZ2Dk", ago: 20_000, app: messages)
        add(.text, "Адрес: Москва, ул. Садовая, д. 12, кв. 34, подъезд 2, этаж 5", ago: 86_000, app: pages, pinned: true)
        add(.text, "Wi-Fi гостевой: MomGuest / пароль на холодильнике", ago: 172_000, app: notes)
        add(.link, "https://www.youtube.com/watch?v=dQw4w9WgXcQ", ago: 400_000, app: safari)
        add(.text, "Рецепт: 3 яйца, стакан сахара, стакан муки, щепотка соли — 40 минут при 180°", ago: 900_000, app: safari)
    }

    static func sampleImage(width: Int = 640, height: Int = 420) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(colors: [NSColor(red: 0.2, green: 0.78, blue: 1, alpha: 1), NSColor(red: 0.07, green: 0.42, blue: 0.93, alpha: 1)])!
            .draw(in: r, angle: -35)
        NSColor(red: 1, green: 0.8, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: width - 190, y: height - 170, width: 120, height: 120)).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        let hill = NSBezierPath()
        hill.move(to: .zero)
        hill.curve(to: NSPoint(x: width, y: 60), controlPoint1: NSPoint(x: width / 3, y: 220),
                   controlPoint2: NSPoint(x: width * 2 / 3, y: -40))
        hill.line(to: NSPoint(x: width, y: 0))
        hill.close()
        hill.fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}

/// `ClipMom --selftest`: всё на отдельном именованном буфере и во временной папке.
/// Общий буфер обмена (`NSPasteboard.general`) здесь не используется вовсе.
enum SelfTest {
    static func run() {
        let fm = FileManager.default
        let pb = NSPasteboard(name: NSPasteboard.Name("local.clipmom.selftest"))
        let dir = fm.temporaryDirectory.appendingPathComponent("clipmom-selftest-\(UUID().uuidString)", isDirectory: true)
        defer {
            pb.releaseGlobally()
            try? fm.removeItem(at: dir)
        }
        let store = HistoryStore(dir: dir)
        let h = History(store: store)
        try! store.prepare()

        var ok = true
        func expect(_ cond: Bool, _ msg: String) { print((cond ? "✓ " : "✗ ") + msg); ok = ok && cond }
        var tracker = ChangeTracker(current: pb.changeCount)
        let app = SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit")

        /// Как в приложении: смена changeCount → чтение → запись в историю.
        @discardableResult
        func capture(_ fill: () -> Void, source: SourceApp? = app, now: Date = .now) -> CaptureResult {
            fill()
            guard tracker.check(pb.changeCount) == .external else { return .skipped("своя запись") }
            let r = PasteboardReader.read(pb)
            if case .captured(let c) = r { _ = try? h.ingest(c, source: source, now: now) }
            return r
        }
        func isSkipped(_ r: CaptureResult) -> Bool { if case .skipped = r { return true } else { return false } }

        if #available(macOS 15.4, *) {
            print("  accessBehavior отдельного буфера: \(pb.accessBehavior.rawValue) (2 = всегда разрешено)")
        }

        // Текст, ссылка, RTF, картинка, файлы
        capture { pb.clearContents(); pb.setString("Привет, мама!", forType: .string) }
        expect(h.items.first?.kind == .text && h.items.first?.text == "Привет, мама!", "текст записан")
        expect(h.items.first?.sourceName == "TextEdit", "источник запомнен")

        capture { pb.clearContents(); pb.setString("https://example.com/путь?x=1", forType: .string) }
        expect(h.items.first?.kind == .link, "ссылка распознана")

        let rtf = NSAttributedString(string: "Жирный текст", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtfData = rtf.rtf(from: NSRange(location: 0, length: rtf.length), documentAttributes: [:])!
        capture { pb.clearContents(); pb.setData(rtfData, forType: .rtf); pb.setString(rtf.string, forType: .string) }
        expect(h.items.first?.text == "Жирный текст" && h.items.first?.rtf != nil, "RTF: сохранён текст и оформление")

        let png = DemoData.sampleImage(width: 300, height: 200)
        capture { pb.clearContents(); pb.setData(png, forType: .png) }
        let img = h.items.first
        expect(img?.kind == .image && img?.pixelWidth == 300, "картинка записана (300×200)")
        let imgFile = img?.image.map(store.imageURL)
        expect(imgFile.map { fm.fileExists(atPath: $0.path) } == true, "PNG сохранён в images/")
        expect(img?.thumb.map { fm.fileExists(atPath: store.imageURL($0).path) } == true, "миниатюра сохранена")

        let tiffImg = DemoData.sampleImage(width: 120, height: 90)
        let tiff2 = NSBitmapImageRep(data: tiffImg)!.tiffRepresentation!
        capture { pb.clearContents(); pb.setData(tiff2, forType: .tiff) }
        expect(h.items.first?.kind == .image && h.items.first?.pixelWidth == 120, "TIFF → PNG")

        let f1 = dir.appendingPathComponent("a.txt"), f2 = dir.appendingPathComponent("b.txt")
        capture { pb.clearContents(); pb.writeObjects([f1 as NSURL, f2 as NSURL]) }
        expect(h.items.first?.kind == .files && h.items.first?.files?.count == 2, "файлы из Finder (2 шт.)")

        // Пропуски
        let before = h.items.count
        for (type, name) in [(NSPasteboard.PasteboardType.concealed, "Concealed"), (.transient, "Transient"),
                             (.autoGenerated, "AutoGenerated"), (.onePassword, "1Password")] {
            let r = capture { pb.clearContents(); pb.setString("секрет-\(name)", forType: .string); pb.setData(Data(), forType: type) }
            expect(isSkipped(r), "пропущен тип \(name)")
        }
        expect(h.items.count == before && !h.items.contains { ($0.text ?? "").hasPrefix("секрет") }, "секреты не попали в историю")

        let prefs = Preferences(defaults: nil)
        expect(prefs.isExcluded("com.1password.1password") != nil && prefs.isExcluded("com.apple.Passwords") != nil
               && prefs.isExcluded("com.apple.keychainaccess") != nil, "менеджеры паролей исключены по умолчанию")

        let big = String(repeating: "я", count: Limits.maxTextBytes / 2 + 10)  // «я» — 2 байта
        expect(isSkipped(capture { pb.clearContents(); pb.setString(big, forType: .string) }), "текст больше 1 МБ пропущен")
        expect(capture { pb.clearContents(); pb.setString("   \n", forType: .string) }.isNothing, "пустой текст не записан")

        // Дедупликация
        let n = h.items.count
        capture { pb.clearContents(); pb.setString("Привет, мама!", forType: .string) }
        expect(h.items.count == n && h.items.first?.text == "Привет, мама!" && h.items.first?.copies == 2,
               "повтор не дублируется, а поднимается наверх")

        // Своя запись в буфер не записывается повторно
        let link = h.items.first { $0.kind == .link }!
        let cc = PasteboardWriter.write(link, to: pb, store: store)
        tracker.markOwnWrite(cc)
        expect(tracker.check(pb.changeCount) == .none, "своя запись ClipMom не считается новой")
        expect(pb.string(forType: .string) == link.text, "запись возвращена в буфер")
        expect(PasteboardReader.skipReason(types: pb.types ?? []) != nil, "своя запись помечена типом local.clipmom.restored")
        let imgCC = PasteboardWriter.write(img!, to: pb, store: store)
        tracker.markOwnWrite(imgCC)
        expect(pb.data(forType: .png) == png, "картинка возвращена в буфер")

        // Хранилище: запись/чтение и права
        try! h.save()
        let h2 = History(store: store)
        h2.load()
        expect(h2.items == h.items, "история читается обратно без потерь (\(h2.items.count) записей)")
        func perms(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1 }
        expect(perms(dir) == 0o700 && perms(store.imagesDir) == 0o700, "папки 0700")
        expect(perms(store.historyURL) == 0o600, "history.json 0600")
        expect(imgFile.map(perms) == 0o600, "картинки 0600")

        // Сроки и лимиты: закреплённые не истекают
        let t = History(store: store)
        t.limits = Limits(maxCount: 5, maxDays: 30)
        let now = Date.now
        for i in 0..<8 {
            t.insertRaw(ClipItem(kind: .text, text: "запись \(i)", bytes: 8, digest: "d\(i)",
                                 created: now - Double(i) * 60, date: now - Double(i) * 60))
        }
        var old = ClipItem(kind: .text, text: "старая", bytes: 6, digest: "old", created: now - 40 * 86_400, date: now - 40 * 86_400)
        t.insertRaw(old)
        old = ClipItem(kind: .text, text: "закреплённая старая", bytes: 6, digest: "pin", created: now - 100 * 86_400,
                       date: now - 100 * 86_400, pinned: true)
        t.insertRaw(old)
        var oldImg = h.items.first { $0.kind == .image && $0.pixelWidth == 120 }!
        oldImg.date = now - 35 * 86_400
        t.insertRaw(oldImg)
        let removed = t.trim(now: now)
        expect(t.items.filter { !$0.pinned }.count == 5, "лимит количества: 5 незакреплённых")
        expect(!t.items.contains { $0.text == "старая" }, "запись старше 30 дней удалена")
        expect(t.items.contains { $0.text == "закреплённая старая" }, "закреплённая запись пережила срок и лимит")
        expect(removed.count == 5 && !fm.fileExists(atPath: store.imageURL(oldImg.image!).path), "файлы удалённой картинки стёрты")

        h.clear(keepPinned: true)
        expect(h.items.isEmpty, "очистка истории")

        print(ok ? "Всё в порядке" : "ЕСТЬ ОШИБКИ")
        exit(ok ? 0 : 1)
    }
}

extension CaptureResult {
    var isNothing: Bool { if case .nothing = self { return true } else { return false } }
}

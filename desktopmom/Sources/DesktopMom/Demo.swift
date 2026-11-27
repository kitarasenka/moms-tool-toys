import Foundation

/// Выдуманные файлы для `--demo`: только в памяти, на диске ничего нет.
enum Demo {
    private static func ago(_ days: Double, _ hours: Double = 0) -> Date {
        Date.now.addingTimeInterval(-(days * 86_400 + hours * 3_600))
    }

    /// Как macOS называет снимок на языке приложения: «Снимок экрана 2026-11-27 в 11.33.57.png», «Screenshot … at ….png».
    private static func shotName(_ d: Date, video: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: d)
        f.dateFormat = "HH.mm.ss"
        let time = f.string(from: d)
        return video ? String(localized: "Запись экрана \(day) в \(time).mov")
                     : String(localized: "Снимок экрана \(day) в \(time).png")
    }

    static func desktop(_ r: Roots) -> [Entry] {
        var out: [Entry] = []
        func add(_ name: String, _ g: DeskGroup, _ size: Int64, _ days: Double, folder: Bool = false) {
            let d = ago(days)
            out.append(Entry(url: r.desktop.appendingPathComponent(name), group: g, size: size, isFolder: folder,
                             created: d, modified: d, lastUsed: nil, added: d))
        }
        // Снимки экрана за несколько месяцев — их больше всего.
        let spread: [Double] = [0.1, 0.4, 1, 1.2, 2, 3, 3.5, 5, 6, 8, 9, 12, 14, 15, 17, 20, 22, 26, 29, 33, 36, 40,
                                44, 47, 51, 55, 58, 63, 70, 77, 84, 92, 101, 118, 130, 151]
        for (i, d) in spread.enumerated() {
            let date = ago(d, Double(i % 7))
            out.append(Entry(url: r.desktop.appendingPathComponent(shotName(date, video: i % 11 == 5)), group: .screenshots,
                             size: Int64(i % 11 == 5 ? 48_000_000 : 900_000 + i * 37_000),
                             created: date, modified: date, lastUsed: nil, added: date))
        }
        add(String(localized: "Квитанция за свет октябрь.pdf"), .documents, 184_000, 31)
        add(String(localized: "Рецепт пирога от Гали.docx"), .documents, 46_000, 64)
        add(String(localized: "Анкета в поликлинику.pdf"), .documents, 312_000, 12)
        add(String(localized: "Список покупок.txt"), .documents, 900, 2)
        add(String(localized: "Паспорт скан.jpg"), .images, 2_400_000, 210)
        add(String(localized: "Внуки на даче.jpg"), .images, 5_100_000, 95)
        add("IMG_4471.HEIC", .images, 3_300_000, 40)
        add(String(localized: "Поздравление.mp4"), .media, 86_000_000, 18)
        add("Zoom.pkg", .installers, 98_000_000, 160)
        add(String(localized: "Фото с юбилея.zip"), .archives, 410_000_000, 120)
        add(String(localized: "Новая папка"), .folders, 12_000_000, 300, folder: true)
        add(String(localized: "Новая папка 2"), .folders, 0, 260, folder: true)
        add(String(localized: "Документы для пенсии"), .folders, 38_000_000, 45, folder: true)
        return out.sorted { $0.size > $1.size }
    }

    static func downloads(_ r: Roots) -> [Entry] {
        var out: [Entry] = []
        func add(_ name: String, _ g: DeskGroup, _ size: Int64, _ days: Double, used: Double? = nil, app: String? = nil) {
            let d = ago(days)
            var e = Entry(url: r.downloads.appendingPathComponent(name), group: g, size: size,
                          created: d, modified: d, lastUsed: used.map { ago($0) }, added: d)
            e.installedMatch = app
            out.append(e)
        }
        add("googlechrome.dmg", .installers, 236_000_000, 210, app: "Google Chrome")
        add("zoomusInstallerFull.pkg", .installers, 98_000_000, 400, app: "zoom.us")
        add("Telegram-macOS-11.2.dmg", .installers, 142_000_000, 25, app: "Telegram")
        add("Skype-8.99.dmg", .installers, 171_000_000, 520)
        add("VLC-3.0.20-universal.dmg", .installers, 54_000_000, 8, app: "VLC")
        add(String(localized: "Фото с юбилея.zip"), .archives, 410_000_000, 120, used: 118)
        add(String(localized: "Выписка_сбербанк_2025.pdf"), .documents, 420_000, 300)
        add(String(localized: "Билеты Москва—Сочи.pdf"), .documents, 210_000, 14, used: 2)
        add(String(localized: "Сериал 1 серия.mp4"), .media, 1_480_000_000, 190)
        add("IMG_20250712_183344.jpg", .images, 4_200_000, 140)
        add(String(localized: "инструкция-мультиварка.pdf"), .documents, 7_800_000, 610)
        add(String(localized: "Договор аренды.docx"), .documents, 88_000, 3, used: 1)
        return out.sorted { $0.size > $1.size }
    }
}

import AppKit
import Carbon.HIToolbox
import Foundation

/// `KeyMom --selftest`: таблицы раскладок, направление, слово перед курсором, буфер обмена на отдельном
/// именованном буфере (общий буфер не трогается), сочетания клавиш.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var passed = 0

    private static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else {
            failures += 1
            print("✗ \(what) \(detail())")
        }
    }

    private static func eq(_ got: String, _ want: String, _ what: String) {
        check(got == want, what, "— получили «\(got)», ждали «\(want)»")
    }

    static func run() {
        conversion()
        detection()
        wordBefore()
        pasteboard()
        hotkeys()
        print(failures == 0 ? "✓ selftest: \(passed) проверок прошли" : "✗ selftest: \(failures) из \(passed + failures) не прошли")
        exit(failures == 0 ? 0 : 1)
    }

    private static func conversion() {
        let C = LayoutConverter.self
        // Обе русские раскладки: буквы одинаковые
        for v in RussianVariant.allCases {
            eq(C.convert("ghbdtn", direction: .toRussian, variant: v), "привет", "ghbdtn→привет [\(v)]")
            eq(C.convert("привет", direction: .toEnglish, variant: v), "ghbdtn", "привет→ghbdtn [\(v)]")
            eq(C.convert("руддщ цщкдв", direction: .toEnglish, variant: v), "hello world", "руддщ цщкдв [\(v)]")
            eq(C.convert("Ghbdtn", direction: .toRussian, variant: v), "Привет", "заглавная [\(v)]")
            eq(C.convert("GHBDTN", direction: .toRussian, variant: v), "ПРИВЕТ", "все заглавные [\(v)]")
            eq(C.convert("[jkjlyj ;bpym", direction: .toRussian, variant: v), "холодно жизнь", "х и ж на [ и ; [\(v)]")
            eq(C.convert("'nj c]tkb", direction: .toRussian, variant: v), "это съели", "э и ъ [\(v)]")
            eq(C.convert("<fnfkbz {fhbnjyjdf", direction: .toRussian, variant: v), "Баталия Харитонова", "Б и Х [\(v)]")
            eq(C.convert("Ve;", direction: .toRussian, variant: v), "Муж", "ж в конце [\(v)]")
            eq(C.convert("123 ntcn", direction: .toRussian, variant: v), "123 тест", "цифры [\(v)]")
            // Туда и обратно — без потерь на всех буквах
            let ru = "съешь же ещё этих мягких французских булок, да выпей чаю"
            let ruUp = ru.uppercased()
            for s in [ru, ruUp] {
                let en = C.convert(s, direction: .toEnglish, variant: v)
                eq(C.convert(en, direction: .toRussian, variant: v), s, "туда-обратно [\(v)] \(s.prefix(10))…")
            }
            let enText = "The quick brown fox jumps over the lazy dog"
            eq(C.convert(C.convert(enText, direction: .toRussian, variant: v), direction: .toEnglish, variant: v), enText,
               "EN туда-обратно [\(v)]")
        }
        // ПК: ё слева от 1, «.» на «/», «,» на Shift+/, «?» на Shift+7, «"» на Shift+2, «№» на Shift+3
        eq(C.convert("Ghbdtn? Rfr ltkf&", direction: .toRussian, variant: .pc), "Привет, Как дела?", "знаки ПК")
        eq(C.convert("`krf, ~krf", direction: .toRussian, variant: .pc), "ёлкаб Ёлка", "ё/Ё ПК")
        eq(C.convert("Lf/ Dhtvz^ 10:30 @Ntcn@ (gjckt ltdznb)", direction: .toRussian, variant: .pc),
           "Да. Время: 10:30 \"Тест\" (после девяти)", "точка, двоеточие, кавычки ПК; время не трогаем")
        eq(C.convert("#ljv", direction: .toRussian, variant: .pc), "№дом", "№ ПК")
        eq(C.convert(":-) ghbdtn", direction: .toRussian, variant: .pc), ":-) привет", "смайлик без букв не трогаем")
        eq(C.convert("Lf, b ytn/", direction: .toRussian, variant: .pc), "Даб и нет.", "запятая-клавиша = б, ПК")
        eq(C.convert("Привет, как дела?", direction: .toEnglish, variant: .pc), "Ghbdtn? rfr ltkf&", "RU→EN знаки ПК")
        // Apple: ё на «\», «]»/«[» на `/~, «.» и «,» на Shift+7 / Shift+6, «%» на Shift+4, «:» на Shift+5, «;» на Shift+8
        eq(C.convert("Ghbdtn^ rfr ltkf?", direction: .toRussian, variant: .mac), "Привет, как дела?", "знаки Apple")
        eq(C.convert("\\krf |krf", direction: .toRussian, variant: .mac), "ёлка Ёлка", "ё/Ё Apple")
        eq(C.convert("Ntrcn& Dhtvz% 10:30", direction: .toRussian, variant: .mac), "Текст. Время: 10:30", "точка, двоеточие Apple")
        eq(C.convert("Ешё", direction: .toEnglish, variant: .mac), "Ti\\", "ё→\\ Apple")
        eq(C.convert("Ешё", direction: .toEnglish, variant: .pc), "Ti`", "ё→` ПК")
        // Смешанный текст: правильно набранное не портится
        eq(C.convert("Привет, ujdjhb uhjvxt", direction: .toRussian, variant: .pc), "Привет, говори громче",
           "смешанный: запятая у русского слова остаётся")
        eq(C.convert("Купи vjkjrj b [kt,", direction: .toRussian, variant: .pc), "Купи молоко и хлеб", "смешанный EN→RU")
        eq(C.convert("Open ащдвук please", direction: .toEnglish, variant: .pc), "Open folder please", "смешанный RU→EN")
        eq(C.convert("  ghbdtn\n\tvbh ", direction: .toRussian, variant: .pc), "  привет\n\tмир ", "пробелы и переносы")
        eq(C.convert("ghbdtn 🙂 vbh", direction: .toRussian, variant: .pc), "привет 🙂 мир", "эмодзи не трогаем")
        // Авто
        check(C.autoConvert("ghbdtn", variant: .pc)?.0 == "привет", "авто EN→RU")
        check(C.autoConvert("руддщ", variant: .pc)?.0 == "hello", "авто RU→EN")
        check(C.autoConvert("12345 !!!", variant: .pc) == nil, "авто: без букв — нечего исправлять")
        check(C.autoConvert("", variant: .pc) == nil, "авто: пусто")
        // Повторное исправление возвращает как было
        if let a = C.autoConvert("ghbdtn", variant: .pc), let b = C.autoConvert(a.0, variant: .pc) {
            eq(b.0, "ghbdtn", "второе нажатие возвращает как было")
        } else { check(false, "второе нажатие") }
    }

    private static func detection() {
        let C = LayoutConverter.self
        check(C.detect("ghbdtn") == .toRussian, "направление: латиница → RU")
        check(C.detect("руддщ") == .toEnglish, "направление: кириллица → EN")
        check(C.detect("Купи vjkjrj b [kt,") == .toRussian, "направление: латиницы больше")
        check(C.detect("Мама мыла раму ok") == .toEnglish, "направление: кириллицы больше")
        check(C.detect("ab вг") == .toRussian, "направление: поровну → RU")
        check(C.detect("ёЁ") == .toEnglish, "ё — кириллица")
        check(C.detect("2024-01-01") == nil, "направление: нет букв")
    }

    private static func wordBefore() {
        func w(_ s: String, _ caret: Int) -> String? {
            let ns = s as NSString
            return AXText.wordBefore(caret: caret, in: ns).map { ns.substring(with: $0) }
        }
        check(w("Привет ghbdtn", 13) == "ghbdtn", "слово перед курсором")
        check(w("Привет ghbdtn  ", 15) == "ghbdtn", "слово перед курсором через пробелы")
        check(w("abc ghbdtn? def", 11) == "ghbdtn?", "со знаком")
        check(w("Привет ghbdtn", 7) == "Привет", "курсор после пробела")
        check(w("строка\n", 7) == nil, "курсор в начале строки")
        check(w("", 0) == nil, "пусто")
        check(w("🙂 ghbdtn", ("🙂 ghbdtn" as NSString).length) == "ghbdtn", "UTF-16 с эмодзи")
    }

    private static func pasteboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("local.keymom.selftest.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        check(pb.name != NSPasteboard.general.name, "отдельный буфер, не общий")

        // Пустой буфер: снимок пустой, восстановление оставляет пустым
        pb.clearContents()
        let empty = PasteboardSnapshot.take(pb)
        check(empty.isEmpty, "снимок пустого буфера")

        // Два элемента, несколько типов
        let custom = NSPasteboard.PasteboardType("local.keymom.test")
        let a = NSPasteboardItem()
        a.setString("оригинал", forType: .string)
        a.setData(Data([1, 2, 3, 4]), forType: custom)
        let rtf = try? NSAttributedString(string: "жирный").data(from: NSRange(location: 0, length: 6),
                                                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        if let rtf { a.setData(rtf, forType: .rtf) }
        let b = NSPasteboardItem()
        b.setString("https://example.com", forType: .string)
        pb.clearContents()
        pb.writeObjects([a, b])
        let snap = PasteboardSnapshot.take(pb)
        check(snap.items.count == 2, "снимок: 2 элемента", "— \(snap.items.count)")

        // Наша временная запись
        let cc = PasteboardWriter.writeTransient("привет", to: pb)
        check(cc == pb.changeCount, "changeCount после записи")
        let types = Set(pb.types ?? [])
        check(pb.string(forType: .string) == "привет", "временная запись: текст")
        check(types.contains(.concealed) && types.contains(.transient), "временная запись помечена Concealed/Transient")
        check(pb.string(forType: .source) == "local.keymom", "временная запись: источник")

        // Восстановление
        snap.restore(to: pb)
        let items = pb.pasteboardItems ?? []
        check(items.count == 2, "восстановлено 2 элемента")
        check(items.first?.string(forType: .string) == "оригинал", "восстановлен текст")
        check(items.first?.data(forType: custom) == Data([1, 2, 3, 4]), "восстановлен свой тип")
        if rtf != nil { check(items.first?.data(forType: .rtf) == rtf, "восстановлен RTF") }
        check(items.count > 1 && items[1].string(forType: .string) == "https://example.com", "восстановлен второй элемент")
        check(items.first?.types.contains(.transient) == true, "восстановленное помечено Transient (не новое копирование)")
        check(!(items.first?.types.contains(.concealed) ?? true), "восстановленное не помечено как пароль")

        // Восстановление пустого
        empty.restore(to: pb)
        check((pb.pasteboardItems ?? []).isEmpty, "восстановлен пустой буфер")
    }

    private static func hotkeys() {
        let all = HotkeyPreset.allCases
        check(Set(all.map(\.title)).count == all.count, "названия сочетаний различаются")
        check(Set(all.map(\.modifiers)).count == all.count, "модификаторы сочетаний различаются")
        eq(HotkeyPreset.shiftCmdSpace.title, "⇧⌘ Пробел", "формат ⇧⌘")
        eq(HotkeyPreset.ctrlOptCmdSpace.title, "⌃⌥⌘ Пробел", "порядок ⌃⌥⇧⌘")
        eq(HotkeyPreset.optShiftSpace.title, "⌥⇧ Пробел", "формат ⌥⇧")
        for p in all {
            check(p.modifiers != 0, "есть модификатор: \(p)")
            check(p.symbols.count == p.keyNames.count, "значки и названия клавиш: \(p)")
            for r in HotkeyPreset.reserved {
                check(!(r.key == p.keyCode && r.mods == p.modifiers), "\(p.title) не совпадает с «\(r.what)»")
            }
        }
        check(Preferences(defaults: nil).hotkey == .shiftCmdSpace, "по умолчанию ⇧⌘ Пробел")
        check(Preferences(defaults: nil).variant == .auto, "по умолчанию русская раскладка определяется сама")
    }
}

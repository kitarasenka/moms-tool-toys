import Foundation

/// Русская раскладка, в которой человек печатает: от неё зависит, где стоят знаки препинания.
enum RussianVariant: String, CaseIterable, Identifiable, Codable {
    /// «Русская – ПК» (`com.apple.keylayout.RussianWin`) — как на Windows: «.» и «,» справа внизу, ё слева от 1.
    case pc
    /// «Русская» (`com.apple.keylayout.Russian`) — вариант Apple: «.» и «,» на Shift+6/7, ё на клавише «\».
    case mac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pc: String(localized: "Русская – ПК")
        case .mac: String(localized: "Русская (Apple)")
        }
    }

    var inputSourceID: String {
        switch self {
        case .pc: "com.apple.keylayout.RussianWin"
        case .mac: "com.apple.keylayout.Russian"
        }
    }
}

/// В какую сторону переделывать текст.
enum Direction: String, CaseIterable, Identifiable {
    /// Печатали по-русски в английской раскладке: ghbdtn → привет.
    case toRussian
    /// Печатали по-английски в русской раскладке: руддщ → hello.
    case toEnglish

    var id: String { rawValue }
    var title: String { self == .toRussian ? "EN → RU" : "RU → EN" }
    var targetLanguage: String { self == .toRussian ? "ru" : "en" }
}

/// Таблицы клавиш: какой символ даёт одна и та же физическая клавиша в английской (US/ABC) и русской раскладке.
/// Перевод идёт «через клавишу»: символ → (клавиша, Shift) → символ той же клавиши в другой раскладке.
enum KeyTable {
    /// Клавиша: (US, US+Shift, ПК, ПК+Shift, Apple, Apple+Shift). Порядок — как на клавиатуре.
    private static let keys: [(String, String, String, String, String, String)] = [
        ("`", "~", "ё", "Ё", "]", "["),  // l10n:skip
        ("1", "!", "1", "!", "1", "!"),
        ("2", "@", "2", "\"", "2", "\""),
        ("3", "#", "3", "№", "3", "№"),
        ("4", "$", "4", ";", "4", "%"),
        ("5", "%", "5", "%", "5", ":"),
        ("6", "^", "6", ":", "6", ","),
        ("7", "&", "7", "?", "7", "."),
        ("8", "*", "8", "*", "8", ";"),
        ("9", "(", "9", "(", "9", "("),
        ("0", ")", "0", ")", "0", ")"),
        ("-", "_", "-", "_", "-", "_"),
        ("=", "+", "=", "+", "=", "+"),
        ("q", "Q", "й", "Й", "й", "Й"), ("w", "W", "ц", "Ц", "ц", "Ц"), ("e", "E", "у", "У", "у", "У"),  // l10n:skip
        ("r", "R", "к", "К", "к", "К"), ("t", "T", "е", "Е", "е", "Е"), ("y", "Y", "н", "Н", "н", "Н"),  // l10n:skip
        ("u", "U", "г", "Г", "г", "Г"), ("i", "I", "ш", "Ш", "ш", "Ш"), ("o", "O", "щ", "Щ", "щ", "Щ"),  // l10n:skip
        ("p", "P", "з", "З", "з", "З"),  // l10n:skip
        ("[", "{", "х", "Х", "х", "Х"),  // l10n:skip
        ("]", "}", "ъ", "Ъ", "ъ", "Ъ"),  // l10n:skip
        ("\\", "|", "\\", "/", "ё", "Ё"),  // l10n:skip
        ("a", "A", "ф", "Ф", "ф", "Ф"), ("s", "S", "ы", "Ы", "ы", "Ы"), ("d", "D", "в", "В", "в", "В"),  // l10n:skip
        ("f", "F", "а", "А", "а", "А"), ("g", "G", "п", "П", "п", "П"), ("h", "H", "р", "Р", "р", "Р"),  // l10n:skip
        ("j", "J", "о", "О", "о", "О"), ("k", "K", "л", "Л", "л", "Л"), ("l", "L", "д", "Д", "д", "Д"),  // l10n:skip
        (";", ":", "ж", "Ж", "ж", "Ж"),  // l10n:skip
        ("'", "\"", "э", "Э", "э", "Э"),  // l10n:skip
        ("z", "Z", "я", "Я", "я", "Я"), ("x", "X", "ч", "Ч", "ч", "Ч"), ("c", "C", "с", "С", "с", "С"),  // l10n:skip
        ("v", "V", "м", "М", "м", "М"), ("b", "B", "и", "И", "и", "И"), ("n", "N", "т", "Т", "т", "Т"),  // l10n:skip
        ("m", "M", "ь", "Ь", "ь", "Ь"),  // l10n:skip
        (",", "<", "б", "Б", "б", "Б"),  // l10n:skip
        (".", ">", "ю", "Ю", "ю", "Ю"),  // l10n:skip
        ("/", "?", ".", ",", "/", "?"),
    ]

    /// Символ → символ для каждой пары (направление, вариант).
    private static let maps: [String: [Character: Character]] = {
        var m: [String: [Character: Character]] = [:]
        for v in RussianVariant.allCases {
            var toRu: [Character: Character] = [:], toEn: [Character: Character] = [:]
            for k in keys {
                let en = [k.0, k.1]
                let ru = v == .pc ? [k.2, k.3] : [k.4, k.5]
                for i in 0..<2 {
                    let e = Character(en[i]), r = Character(ru[i])
                    if toRu[e] == nil { toRu[e] = r }
                    if toEn[r] == nil { toEn[r] = e }
                }
            }
            m[key(.toRussian, v)] = toRu
            m[key(.toEnglish, v)] = toEn
        }
        return m
    }()

    private static func key(_ d: Direction, _ v: RussianVariant) -> String { "\(d.rawValue)-\(v.rawValue)" }

    static func map(_ d: Direction, _ v: RussianVariant) -> [Character: Character] { maps[key(d, v)] ?? [:] }
}

enum LayoutConverter {
    static func isLatinLetter(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (0x41...0x5A).contains(s.value) || (0x61...0x7A).contains(s.value)
    }

    static func isCyrillicLetter(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (0x410...0x44F).contains(s.value) || s.value == 0x401 || s.value == 0x451
    }

    /// Направление по преобладанию букв: латиницы больше (или поровну) — переводим в русский.
    /// nil — букв нет вообще, исправлять нечего.
    static func detect(_ text: String) -> Direction? {
        var latin = 0, cyr = 0
        for c in text {
            if isLatinLetter(c) { latin += 1 } else if isCyrillicLetter(c) { cyr += 1 }
        }
        if latin == 0 && cyr == 0 { return nil }
        return cyr > latin ? .toEnglish : .toRussian
    }

    /// Переделывает текст. Знаки препинания меняются только в «словах», где есть буквы исходной раскладки:
    /// в «Привет, ujdjhb» запятая после «Привет» остаётся запятой, а «ujdjhb» станет «говори».
    static func convert(_ text: String, direction: Direction, variant: RussianVariant) -> String {
        let map = KeyTable.map(direction, variant)
        let isSource: (Character) -> Bool = direction == .toRussian ? isLatinLetter : isCyrillicLetter
        var out = ""
        out.reserveCapacity(text.count)
        var word: [Character] = []

        func flush() {
            guard !word.isEmpty else { return }
            if word.contains(where: isSource) {
                for c in word { out.append(map[c] ?? c) }
            } else {
                out.append(contentsOf: word)
            }
            word.removeAll(keepingCapacity: true)
        }

        for c in text {
            if c.isWhitespace || c.isNewline {
                flush()
                out.append(c)
            } else {
                word.append(c)
            }
        }
        flush()
        return out
    }

    /// Автоматически: направление по буквам. nil — нечего исправлять.
    static func autoConvert(_ text: String, variant: RussianVariant) -> (String, Direction)? {
        guard let d = detect(text) else { return nil }
        let r = convert(text, direction: d, variant: variant)
        return r == text ? nil : (r, d)
    }
}

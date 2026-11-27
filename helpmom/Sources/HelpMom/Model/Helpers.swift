import Foundation

/// Тот, кого зовём на помощь: имя и как связаться.
struct Helper: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var phone: String = ""
    var email: String = ""
    var telegram: String = ""

    /// Для FaceTime и Сообщений: телефон, если он есть, иначе e-mail.
    var appleHandle: String? { Contact.phone(phone) ?? Contact.email(email) }
    var telegramName: String? { Contact.telegram(telegram) }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

// MARK: - Ссылки для связи (без сети: только открывают FaceTime, Сообщения, Telegram)

enum Contact {
    /// «+7 (999) 123-45-67» → «+79991234567». nil — не похоже на номер.
    static func phone(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let digits = t.filter(\.isNumber)
        guard digits.count >= 5, digits.count <= 15,
              t.allSatisfy({ $0.isNumber || " +-()./".contains($0) }) else { return nil }
        return (t.hasPrefix("+") ? "+" : "") + digits
    }

    static func email(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.wholeMatch(of: #/[^@\s\/?#&]+@[^@\s\/?#&]+\.[^@\s\/?#&]+/#) != nil else { return nil }
        return t
    }

    /// «@masha_k», «t.me/masha_k», «https://t.me/masha_k» → «masha_k». nil — недопустимое имя.
    static func telegram(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        for p in ["https://", "http://", "www.", "t.me/", "telegram.me/", "tg://resolve?domain=", "@"] where t.lowercased().hasPrefix(p) {
            t = String(t.dropFirst(p.count))
        }
        if t.lowercased().hasPrefix("t.me/") { t = String(t.dropFirst(5)) }
        guard t.wholeMatch(of: #/[A-Za-z][A-Za-z0-9_]{3,31}/#) != nil else { return nil }
        return t
    }

    private static let handleChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+.@_-"))

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: handleChars) ?? s
    }

    static func faceTime(_ handle: String, audio: Bool) -> URL? {
        URL(string: (audio ? "facetime-audio://" : "facetime://") + encode(handle))
    }

    static func iMessage(_ handle: String) -> URL? {
        URL(string: "imessage://" + encode(handle))
    }

    /// Приложение Telegram (tg://) и веб-ссылка — на случай, если приложения нет.
    static func telegramApp(_ user: String) -> URL? { URL(string: "tg://resolve?domain=" + encode(user)) }
    static func telegramWeb(_ user: String) -> URL? { URL(string: "https://t.me/" + encode(user)) }
}

// MARK: - Хранение

/// `~/Library/Application Support/HelpMom/helpers.json`: папка 0700, файл 0600.
struct HelperStore {
    let dir: URL
    var file: URL { dir.appendingPathComponent("helpers.json") }

    static var defaultDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HelpMom")
    }

    func load() -> [Helper] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Helper].self, from: data)) ?? []
    }

    func save(_ helpers: [Helper]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(helpers).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

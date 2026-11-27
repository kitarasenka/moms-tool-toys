import CryptoKit
import Foundation

/// Что лежит в записи истории.
enum ClipKind: String, Codable, CaseIterable {
    case text, link, image, files

    var title: String {
        switch self {
        case .text: String(localized: "Текст")
        case .link: String(localized: "Ссылка")
        case .image: String(localized: "Картинка")
        case .files: String(localized: "Файлы")
        }
    }

    var icon: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }
}

/// Одна запись истории буфера обмена. Хранится в history.json; картинка — отдельным PNG в images/.
struct ClipItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ClipKind
    /// Текст, адрес ссылки или пути файлов через перевод строки.
    var text: String?
    /// Оформленный текст (RTF), если он был и не слишком велик.
    var rtf: Data?
    var files: [String]?
    /// Имена файлов в images/ (картинка и миниатюра).
    var image: String?
    var thumb: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var bytes: Int
    /// SHA-256 содержимого — для «то же самое скопировали ещё раз».
    var digest: String
    var created: Date
    /// Когда копировали последний раз; по этой дате сортируется список и считается срок хранения.
    var date: Date
    var pinned = false
    var sourceID: String?
    var sourceName: String?
    var copies = 1

    /// Короткий заголовок для списков: первая непустая строка.
    var title: String {
        switch kind {
        case .image:
            if let w = pixelWidth, let h = pixelHeight { return String(localized: "Картинка \(w)×\(h)") }
            return String(localized: "Картинка")
        case .files:
            let names = (files ?? []).map { ($0 as NSString).lastPathComponent }
            if names.count <= 1 { return names.first ?? String(localized: "Файл") }
            return String(localized: "\(names[0]) и ещё \(names.count - 1)")
        case .text, .link:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let first = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
            return String(first.prefix(200))
        }
    }

    var searchText: String {
        [text ?? "", sourceName ?? "", kind == .image ? String(localized: "картинка") : ""].joined(separator: " ")
    }

    var url: URL? { kind == .link ? LinkDetector.detect(text ?? "") : nil }
}

struct SourceApp: Equatable {
    var bundleID: String?
    var name: String?
}

/// Фильтры в боковой панели.
enum ClipFilter: String, CaseIterable, Identifiable {
    case all, text, link, image, files, pinned
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "Всё")
        case .text: String(localized: "Текст")
        case .link: String(localized: "Ссылки")
        case .image: String(localized: "Картинки")
        case .files: String(localized: "Файлы")
        case .pinned: String(localized: "Закреплённые")
        }
    }

    var icon: String {
        switch self {
        case .all: "tray.full"
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .files: "doc.on.doc"
        case .pinned: "pin"
        }
    }

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: true
        case .pinned: item.pinned
        case .text: item.kind == .text
        case .link: item.kind == .link
        case .image: item.kind == .image
        case .files: item.kind == .files
        }
    }
}

enum LinkDetector {
    private static let schemes: Set<String> = ["http", "https", "ftp", "mailto", "ssh", "sftp", "file", "tel"]

    /// Весь текст — одна ссылка (без пробелов внутри)?
    static func detect(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 4096, !t.contains(where: { $0.isWhitespace }) else { return nil }
        if let u = URL(string: t), let scheme = u.scheme?.lowercased(), schemes.contains(scheme),
           u.host != nil || ["mailto", "tel", "file"].contains(scheme) {
            return u
        }
        if t.lowercased().hasPrefix("www."), let u = URL(string: "https://" + t), u.host != nil { return u }
        return nil
    }
}

enum Digest {
    static func of(_ data: Data, salt: String) -> String {
        var h = SHA256()
        h.update(data: Data(salt.utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Ограничения истории.
struct Limits: Equatable {
    var maxCount = 300
    var maxDays = 30
    static let maxTextBytes = 1_000_000
    static let maxImageBytes = 20_000_000
    static let maxRTFBytes = 512_000
}

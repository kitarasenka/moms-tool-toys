import AppKit

extension NSPasteboard.PasteboardType {
    // Соглашения nspasteboard.org: менеджеры буфера (ClipMom и др.) такие записи не сохраняют.
    static let concealed = Self("org.nspasteboard.ConcealedType")
    static let transient = Self("org.nspasteboard.TransientType")
    /// Кто положил данные в буфер (bundle id).
    static let source = Self("org.nspasteboard.source")
}

/// Полная копия буфера обмена: все элементы и все их типы. Нужна, чтобы после исправления
/// вернуть в буфер то, что там было до нажатия сочетания.
struct PasteboardSnapshot {
    var items: [[(NSPasteboard.PasteboardType, Data)]]

    static func take(_ pb: NSPasteboard) -> PasteboardSnapshot {
        var items: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in pb.pasteboardItems ?? [] {
            var entry: [(NSPasteboard.PasteboardType, Data)] = []
            for t in item.types {
                if let d = item.data(forType: t) { entry.append((t, d)) }
            }
            if !entry.isEmpty { items.append(entry) }
        }
        return PasteboardSnapshot(items: items)
    }

    var isEmpty: Bool { items.isEmpty }

    /// Возвращает содержимое. Помечает его «временным», чтобы менеджеры буфера не записали его
    /// как новое копирование (это то же самое, что было в буфере раньше).
    @discardableResult
    func restore(to pb: NSPasteboard) -> Int {
        pb.clearContents()
        guard !items.isEmpty else { return pb.changeCount }
        let objects: [NSPasteboardItem] = items.enumerated().map { i, entry in
            let it = NSPasteboardItem()
            for (t, d) in entry { it.setData(d, forType: t) }
            if i == 0 && !entry.contains(where: { $0.0 == .transient }) {
                it.setData(Data(), forType: .transient)
            }
            return it
        }
        pb.writeObjects(objects)
        return pb.changeCount
    }
}

enum ClipText {
    /// ⌘C без выделения в VS Code, JetBrains, Sublime копирует всю текущую строку с переводом строки на конце.
    /// Признак: ровно одна строка и она заканчивается переводом строки. Обычное выделение слова или фразы так
    /// не выглядит; редкий случай «выделили строку целиком» KeyMom обработает как «нет выделения» — без дублей.
    static func looksLikeWholeLineCopy(_ s: String) -> Bool {
        guard let last = s.last, last.isNewline else { return false }
        return !s.dropLast().contains(where: \.isNewline)
    }
}

enum PasteboardWriter {
    /// Кладёт исправленный текст для ⌘V. Помечен скрытым и временным — в историю ClipMom не попадёт.
    @discardableResult
    static func writeTransient(_ s: String, to pb: NSPasteboard) -> Int {
        pb.clearContents()
        pb.declareTypes([.string, .concealed, .transient, .source], owner: nil)
        pb.setString(s, forType: .string)
        pb.setData(Data(), forType: .concealed)
        pb.setData(Data(), forType: .transient)
        pb.setString("local.keymom", forType: .source)
        return pb.changeCount
    }

    /// «Скопировать» в окне: обычная запись (пусть сохранится в истории), только с меткой источника.
    static func writePlain(_ s: String, to pb: NSPasteboard) {
        pb.clearContents()
        pb.declareTypes([.string, .source], owner: nil)
        pb.setString(s, forType: .string)
        pb.setString("local.keymom", forType: .source)
    }
}

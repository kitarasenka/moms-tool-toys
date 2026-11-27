import AppKit
import ApplicationServices

/// Чтение и замена текста в чужом приложении через Accessibility API — без буфера обмена.
/// Работает в обычных macOS-приложениях (Заметки, TextEdit, Почта, Safari, Pages…);
/// где не работает (часть браузеров и Electron-приложений), KeyMom переходит на ⌘C/⌘V.
enum AXText {
    struct Target {
        let element: AXUIElement
        let range: CFRange      // что заменяем (в UTF-16)
        let text: String        // исходный текст в этом диапазоне
        let fromSelection: Bool // было выделение или взяли слово перед курсором
    }

    static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.5)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let el = v as! AXUIElement  // проверено по CFTypeID
        AXUIElementSetMessagingTimeout(el, 0.5)
        return el
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func selectedRange(_ el: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    @discardableResult
    static func setSelectedRange(_ el: AXUIElement, _ r: CFRange) -> Bool {
        var r = r
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Слово перед курсором (как ⌥⇧←): пропустить пробелы назад, затем всё до предыдущего пробела.
    /// Диапазон в UTF-16; nil — перед курсором пусто.
    static func wordBefore(caret: Int, in text: NSString) -> NSRange? {
        guard caret > 0, caret <= text.length else { return nil }
        let ws = CharacterSet.whitespacesAndNewlines
        func isSpace(_ i: Int) -> Bool {
            guard let u = UnicodeScalar(text.character(at: i)) else { return false }
            return ws.contains(u)
        }
        var end = caret
        while end > 0, isSpace(end - 1) {
            if text.character(at: end - 1) == 10 || text.character(at: end - 1) == 13 { return nil }  // курсор в начале строки
            end -= 1
        }
        var start = end
        while start > 0, !isSpace(start - 1) { start -= 1 }
        guard start < end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Что исправлять: выделение, а если его нет — слово перед курсором.
    static func target() -> Target? {
        guard let el = focusedElement(), let sel = selectedRange(el) else { return nil }
        if sel.length > 0, let s = string(el, kAXSelectedTextAttribute), !s.isEmpty {
            return Target(element: el, range: sel, text: s, fromSelection: true)
        }
        guard let value = string(el, kAXValueAttribute) else { return nil }
        let ns = value as NSString
        guard let w = wordBefore(caret: sel.location, in: ns) else { return nil }
        return Target(element: el, range: CFRange(location: w.location, length: w.length),
                      text: ns.substring(with: w), fromSelection: false)
    }

    enum ReplaceResult: Equatable {
        case replaced   // на месте уже новый текст
        case unchanged  // на месте всё ещё исходный текст — можно безопасно вставить через буфер
        case unknown    // ни то ни другое (приложение отдаёт текст с задержкой или иначе) — второй раз не вставлять
    }

    /// Что сейчас лежит в тексте элемента с позиции location длиной length (UTF-16); nil — не прочитать.
    static func text(_ el: AXUIElement, at location: Int, length: Int) -> String? {
        guard let value = string(el, kAXValueAttribute) else { return nil }
        let ns = value as NSString
        guard location >= 0, length >= 0, location + length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: location, length: length))
    }

    /// Классифицирует состояние после попытки замены: по месту диапазона лежит новый текст, старый или непонятно что.
    static func check(_ t: Target, new: String) -> ReplaceResult {
        if text(t.element, at: t.range.location, length: (new as NSString).length) == new { return .replaced }
        if text(t.element, at: t.range.location, length: t.range.length) == t.text { return .unchanged }
        return .unknown
    }

    /// Заменяет диапазон на новый текст и проверяет, что приложение действительно его поменяло
    /// (некоторые отвечают «успех», но ничего не делают, а некоторые — Chrome, Electron — обновляют
    /// AXValue с задержкой). Проверка ждёт до ~0,3 с; вставлять через буфер можно только при `.unchanged`,
    /// иначе слово задвоится.
    static func replace(_ t: Target, with new: String) async -> ReplaceResult {
        guard setSelectedRange(t.element, t.range) else { return .unchanged }
        let err = AXUIElementSetAttributeValue(t.element, kAXSelectedTextAttribute as CFString, new as CFString)
        var state = check(t, new: new)
        // Ошибка установки и текст не тронут — приложение замену не поддерживает, ждать нечего.
        if err != .success && state == .unchanged { return .unchanged }
        for _ in 0..<6 where state != .replaced {
            try? await Task.sleep(for: .milliseconds(50))
            state = check(t, new: new)
        }
        return state
    }
}

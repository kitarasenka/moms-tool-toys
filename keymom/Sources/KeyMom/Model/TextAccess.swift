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

    /// Заменяет диапазон на новый текст и проверяет, что приложение действительно его поменяло
    /// (некоторые отвечают «успех», но ничего не делают).
    static func replace(_ t: Target, with new: String) -> Bool {
        guard setSelectedRange(t.element, t.range) else { return false }
        guard AXUIElementSetAttributeValue(t.element, kAXSelectedTextAttribute as CFString, new as CFString) == .success else {
            return false
        }
        guard let value = string(t.element, kAXValueAttribute) else { return false }
        let ns = value as NSString
        let len = (new as NSString).length
        guard t.range.location + len <= ns.length else { return false }
        return ns.substring(with: NSRange(location: t.range.location, length: len)) == new
    }
}

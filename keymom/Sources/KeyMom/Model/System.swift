import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

/// Готовые сочетания для «Исправить раскладку». Все — с пробелом: так одинаково удобно в любой раскладке
/// и не занято системой (⌃Space и ⌃⌥Space — переключение раскладок, ⌘Space — Spotlight,
/// ⌃⌘Space — эмодзи, ⌥⌘Space — поиск Finder, ⇧⌘V — быстрая панель ClipMom).
enum HotkeyPreset: String, CaseIterable, Identifiable, Codable {
    case shiftCmdSpace, ctrlShiftSpace, optShiftSpace, ctrlOptCmdSpace

    var id: String { rawValue }

    var keyCode: Int { kVK_Space }

    var modifiers: Int {
        switch self {
        case .shiftCmdSpace: cmdKey | shiftKey
        case .ctrlShiftSpace: controlKey | shiftKey
        case .optShiftSpace: optionKey | shiftKey
        case .ctrlOptCmdSpace: controlKey | optionKey | cmdKey
        }
    }

    /// Значки модификаторов в принятом в macOS порядке: ⌃⌥⇧⌘.
    var symbols: [String] {
        var s: [String] = []
        if modifiers & controlKey != 0 { s.append("⌃") }
        if modifiers & optionKey != 0 { s.append("⌥") }
        if modifiers & shiftKey != 0 { s.append("⇧") }
        if modifiers & cmdKey != 0 { s.append("⌘") }
        return s
    }

    /// «⇧⌘ Пробел»
    var title: String { symbols.joined() + " " + String(localized: "Пробел") }

    /// Названия клавиш для картинки-подсказки.
    var keyNames: [String] {
        var s: [String] = []
        if modifiers & controlKey != 0 { s.append("control") }
        if modifiers & optionKey != 0 { s.append("option") }
        if modifiers & shiftKey != 0 { s.append("shift") }
        if modifiers & cmdKey != 0 { s.append("command") }
        return s
    }

    /// Сочетания, которые уже заняты системой или другими инструментами (для проверки в selftest).
    static let reserved: [(key: Int, mods: Int, what: String)] = [
        (kVK_Space, controlKey, "переключение раскладки"),  // l10n:skip
        (kVK_Space, controlKey | optionKey, "переключение раскладки"),  // l10n:skip
        (kVK_Space, cmdKey, "Spotlight"),  // l10n:skip
        (kVK_Space, cmdKey | controlKey, "эмодзи"),  // l10n:skip
        (kVK_Space, cmdKey | optionKey, "поиск Finder"),  // l10n:skip
        (kVK_ANSI_V, cmdKey | shiftKey, "ClipMom"),
    ]
}

/// Глобальное сочетание через Carbon `RegisterEventHotKey` — разрешений не требует.
final class HotKey {
    static var onPress: (() -> Void)?
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?

    var isRegistered: Bool { ref != nil }

    @discardableResult
    func register(_ preset: HotkeyPreset) -> Bool {
        unregister()
        if !Self.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.onPress?() }
                return noErr
            }, 1, &spec, nil, nil)
            Self.handlerInstalled = status == noErr
        }
        let id = EventHotKeyID(signature: OSType(0x4B45_594D), id: 1)  // 'KEYM'
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(preset.keyCode), UInt32(preset.modifiers), id,
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr else { return false }
        ref = newRef
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// «Универсальный доступ» — нужен, чтобы нажимать ⌘C/⌘V за пользователя.
enum Accessibility {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Системный запрос (только по действию пользователя).
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }
}

/// Нажатия клавиш за пользователя (CGEvent). Работают только с «Универсальным доступом».
enum KeyPress {
    static func post(_ key: Int, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let code = CGKeyCode(key)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func copy() { post(kVK_ANSI_C, flags: .maskCommand) }
    static func paste() { post(kVK_ANSI_V, flags: .maskCommand) }
    /// ⌥⇧← — выделить слово перед курсором.
    static func selectWordLeft() { post(kVK_LeftArrow, flags: [.maskAlternate, .maskShift]) }

    /// Зажаты ли ещё модификаторы (пользователь не отпустил сочетание).
    static var modifiersHeld: Bool {
        let f = CGEventSource.flagsState(.combinedSessionState)
        return !f.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty
    }
}

/// Caps Lock и безопасный ввод (поле пароля) — без разрешений.
enum KeyboardState {
    static var capsLock: Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) }
    /// Включён «безопасный ввод»: обычно это значит, что курсор в поле пароля.
    static var secureInput: Bool { IsSecureEventInputEnabled() }
}

/// Автозапуск через `SMAppService.mainApp`. С ad-hoc подписью может не сработать — показываем причину.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var enabled: Bool { status == .enabled }

    static var statusText: String {
        switch status {
        case .enabled: String(localized: "Включён")
        case .requiresApproval: String(localized: "Ждёт разрешения в «Объектах входа»")
        case .notFound: String(localized: "Недоступен (запустите KeyMom из .app)")
        case .notRegistered: String(localized: "Выключен")
        @unknown default: String(localized: "Неизвестно")
        }
    }

    /// Возвращает текст ошибки или nil.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if on && status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return String(localized: "Разрешите KeyMom в «Системные настройки → Основные → Объекты входа».")
            }
            return nil
        } catch {
            return String(localized: "Не получилось: \(error.localizedDescription)")
        }
    }
}

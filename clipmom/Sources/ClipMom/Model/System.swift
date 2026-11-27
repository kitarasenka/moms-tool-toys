import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

/// Глобальное сочетание ⇧⌘V через Carbon `RegisterEventHotKey` — разрешений не требует.
final class HotKey {
    static var onPress: (() -> Void)?
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?

    var isRegistered: Bool { ref != nil }

    @discardableResult
    func register(keyCode: Int = kVK_ANSI_V, modifiers: Int = cmdKey | shiftKey) -> Bool {
        unregister()
        if !Self.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.onPress?() }
                return noErr
            }, 1, &spec, nil, nil)
            Self.handlerInstalled = status == noErr
        }
        let id = EventHotKeyID(signature: OSType(0x434C_4D4D), id: 1)  // 'CLMM'
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr else { return false }
        ref = newRef
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// «Вставлять сразу»: после выбора в быстрой панели нажать ⌘V за пользователя.
/// Нужен доступ к Универсальному доступу; спрашиваем только когда пользователь включает функцию.
enum AutoPaste {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос (только по действию пользователя).
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    static func pressCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Автозапуск через `SMAppService.mainApp`. С ad-hoc подписью может не сработать — показываем причину.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var enabled: Bool { status == .enabled }

    static var statusText: String {
        switch status {
        case .enabled: String(localized: "Включён")
        case .requiresApproval: String(localized: "Ждёт разрешения в «Объектах входа»")
        case .notFound: String(localized: "Недоступен (запустите ClipMom из .app)")
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
                return String(localized: "Разрешите ClipMom в «Системные настройки → Основные → Объекты входа».")
            }
            return nil
        } catch {
            return String(localized: "Не получилось: \(error.localizedDescription)")
        }
    }
}

/// Иконки приложений-источников (по bundle id) с кэшем.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let id = bundleID else { return nil }
        if let i = cache[id] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = i
        return i
    }

    static func appInfo(at url: URL) -> ExcludedApp? {
        guard let b = Bundle(url: url), let id = b.bundleIdentifier else { return nil }
        let name = (b.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (b.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (b.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return ExcludedApp(bundleID: id, name: name)
    }
}

/// Миниатюры и картинки из images/ с кэшем.
enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ name: String?, store: HistoryStore) -> NSImage? {
        guard let name else { return nil }
        if let i = cache.object(forKey: name as NSString) { return i }
        guard let i = NSImage(contentsOf: store.imageURL(name)) else { return nil }
        cache.setObject(i, forKey: name as NSString)
        return i
    }
}

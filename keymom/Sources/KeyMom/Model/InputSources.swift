import AppKit
import Carbon

/// Источник ввода (раскладка клавиатуры) — то, что переключается ⌃Space.
struct InputSourceInfo: Equatable {
    var id: String
    var name: String
    var language: String  // "ru", "en", … (первый язык источника)

    /// Код для строки меню: RU, EN, UK…
    var code: String {
        let l = language.split(separator: "-").first.map(String.init) ?? language
        return l.isEmpty ? "?" : l.uppercased()
    }

    var flag: String {
        switch language.split(separator: "-").first.map(String.init) ?? "" {
        case "ru": "🇷🇺"
        case "en": id.contains("British") || language == "en-GB" ? "🇬🇧" : "🇺🇸"
        case "uk": "🇺🇦"
        case "be": "🇧🇾"
        case "kk": "🇰🇿"
        case "de": "🇩🇪"
        case "fr": "🇫🇷"
        case "es": "🇪🇸"
        case "it": "🇮🇹"
        case "ka": "🇬🇪"
        case "hy": "🇦🇲"
        case "tr": "🇹🇷"
        case "he": "🇮🇱"
        case "zh", "zh-Hans", "zh-Hant": "🇨🇳"
        default: "⌨️"
        }
    }
}

/// Работа с Text Input Sources (TIS). Вызывать на главном потоке.
enum InputSources {
    private static func string(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    private static func languages(_ src: TISInputSource) -> [String] {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]) ?? []
    }

    private static func info(_ src: TISInputSource) -> InputSourceInfo {
        InputSourceInfo(id: string(src, kTISPropertyInputSourceID) ?? "",
                        name: string(src, kTISPropertyLocalizedName) ?? "",
                        language: languages(src).first ?? "")
    }

    static func current() -> InputSourceInfo? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return info(src)
    }

    /// Раскладки, которые можно выбрать (включены в «Источниках ввода»).
    private static func selectable() -> [TISInputSource] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list
    }

    static func enabled() -> [InputSourceInfo] { selectable().map(info) }

    /// Какую русскую раскладку использовать «автоматически»: текущую, если выбрана русская;
    /// иначе ту, что включена (ПК — если включены обе или ни одной).
    static func detectRussianVariant() -> RussianVariant {
        if let cur = current()?.id {
            if cur == RussianVariant.pc.inputSourceID { return .pc }
            if cur == RussianVariant.mac.inputSourceID { return .mac }
        }
        let ids = Set(enabled().map(\.id))
        if ids.contains(RussianVariant.mac.inputSourceID) && !ids.contains(RussianVariant.pc.inputSourceID) { return .mac }
        return .pc
    }

    /// Переключает на раскладку нужного языка. Для русского — предпочитает указанный вариант,
    /// для английского — ABC или U.S. Возвращает false, если такой раскладки нет среди включённых.
    @discardableResult
    static func select(language: String, preferRussian variant: RussianVariant) -> Bool {
        let all = selectable()
        let preferred: [String] = language == "ru"
            ? [variant.inputSourceID, RussianVariant.pc.inputSourceID, RussianVariant.mac.inputSourceID]
            : ["com.apple.keylayout.ABC", "com.apple.keylayout.US", "com.apple.keylayout.British",
               "com.apple.keylayout.USInternational-PC"]
        if let cur = current(), cur.language.hasPrefix(language) { return true }
        for id in preferred {
            if let src = all.first(where: { string($0, kTISPropertyInputSourceID) == id }) {
                return TISSelectInputSource(src) == noErr
            }
        }
        if let src = all.first(where: { languages($0).first?.hasPrefix(language) == true }) {
            return TISSelectInputSource(src) == noErr
        }
        return false
    }

    static func openSettings() {
        for s in ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
                  "x-apple.systempreferences:com.apple.preference.keyboard"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }
}

/// Уведомление о смене раскладки. Через CFNotificationCenter с `deliverImmediately` — иначе,
/// пока KeyMom не активен (а он почти всегда в фоне), распределённые уведомления придерживаются.
final class InputSourceObserver {
    static var onChange: (() -> Void)?
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(), nil,
            { _, _, _, _, _ in DispatchQueue.main.async { InputSourceObserver.onChange?() } },
            kTISNotifySelectedKeyboardInputSourceChanged, nil, .deliverImmediately)
    }
}

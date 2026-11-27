import Foundation
import Observation

/// Как показывать раскладку в строке меню.
enum IndicatorStyle: String, CaseIterable, Identifiable {
    case code   // RU / EN
    case flag   // 🇷🇺 / 🇺🇸
    case icon   // только значок клавиатуры

    var id: String { rawValue }

    var title: String {
        switch self {
        case .code: "Буквы (RU / EN)"
        case .flag: "Флажок"
        case .icon: "Только значок"
        }
    }
}

/// Какую русскую раскладку считать «своей».
enum VariantChoice: String, CaseIterable, Identifiable {
    case auto, pc, mac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Определять самому"
        case .pc: RussianVariant.pc.title
        case .mac: RussianVariant.mac.title
        }
    }
}

/// Настройки в UserDefaults. В демо-режиме (`defaults == nil`) ничего не сохраняется.
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults?

    var hotkeyEnabled: Bool { didSet { defaults?.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    var hotkey: HotkeyPreset { didSet { defaults?.set(hotkey.rawValue, forKey: "hotkey") } }
    /// После исправления переключить раскладку на язык исправленного текста.
    var switchLayout: Bool { didSet { defaults?.set(switchLayout, forKey: "switchLayout") } }
    var variant: VariantChoice { didSet { defaults?.set(variant.rawValue, forKey: "variant") } }
    var indicator: IndicatorStyle { didSet { defaults?.set(indicator.rawValue, forKey: "indicator") } }
    /// Плашка «RU»/«EN» у курсора при смене раскладки.
    var layoutHUD: Bool { didSet { defaults?.set(layoutHUD, forKey: "layoutHUD") } }
    /// Плашка при включении Caps Lock.
    var capsHUD: Bool { didSet { defaults?.set(capsHUD, forKey: "capsHUD") } }
    /// Предупреждение «Caps Lock в поле пароля».
    var capsPasswordWarning: Bool { didSet { defaults?.set(capsPasswordWarning, forKey: "capsPasswordWarning") } }
    /// false — KeyMom живёт только в строке меню (без значка в Dock).
    var showInDock: Bool { didSet { defaults?.set(showInDock, forKey: "showInDock") } }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let d = defaults
        func bool(_ k: String, _ def: Bool) -> Bool { (d?.object(forKey: k) as? Bool) ?? def }
        hotkeyEnabled = bool("hotkeyEnabled", true)
        hotkey = d?.string(forKey: "hotkey").flatMap(HotkeyPreset.init(rawValue:)) ?? .shiftCmdSpace
        switchLayout = bool("switchLayout", true)
        variant = d?.string(forKey: "variant").flatMap(VariantChoice.init(rawValue:)) ?? .auto
        indicator = d?.string(forKey: "indicator").flatMap(IndicatorStyle.init(rawValue:)) ?? .code
        layoutHUD = bool("layoutHUD", true)
        capsHUD = bool("capsHUD", true)
        capsPasswordWarning = bool("capsPasswordWarning", true)
        showInDock = bool("showInDock", true)
    }
}

import Foundation
import Observation

struct ExcludedApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }

    /// Менеджеры паролей: что из них скопировано — не записываем.
    static let defaults: [ExcludedApp] = [
        ExcludedApp(bundleID: "com.apple.keychainaccess", name: "Связка ключей"),
        ExcludedApp(bundleID: "com.apple.Passwords", name: "Пароли"),
        ExcludedApp(bundleID: "com.1password.1password", name: "1Password"),
        ExcludedApp(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        ExcludedApp(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
        ExcludedApp(bundleID: "org.keepassxc.keepassxc", name: "KeePassXC"),
    ]
}

/// Настройки в UserDefaults. В демо-режиме (`defaults == nil`) ничего не сохраняется.
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults?

    var maxCount: Int { didSet { defaults?.set(maxCount, forKey: "maxCount") } }
    var maxDays: Int { didSet { defaults?.set(maxDays, forKey: "maxDays") } }
    var hotkeyEnabled: Bool { didSet { defaults?.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    var autoPaste: Bool { didSet { defaults?.set(autoPaste, forKey: "autoPaste") } }
    /// false — ClipMom живёт только в строке меню (без значка в Dock).
    var showInDock: Bool { didSet { defaults?.set(showInDock, forKey: "showInDock") } }
    var onboardingDismissed: Bool { didSet { defaults?.set(onboardingDismissed, forKey: "onboardingDismissed") } }
    var excluded: [ExcludedApp] {
        didSet { defaults?.set(try? JSONEncoder().encode(excluded), forKey: "excludedApps") }
    }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let d = defaults
        maxCount = (d?.object(forKey: "maxCount") as? Int) ?? 300
        maxDays = (d?.object(forKey: "maxDays") as? Int) ?? 30
        hotkeyEnabled = (d?.object(forKey: "hotkeyEnabled") as? Bool) ?? true
        autoPaste = d?.bool(forKey: "autoPaste") ?? false
        showInDock = (d?.object(forKey: "showInDock") as? Bool) ?? true
        onboardingDismissed = d?.bool(forKey: "onboardingDismissed") ?? false
        if let data = d?.data(forKey: "excludedApps"), let list = try? JSONDecoder().decode([ExcludedApp].self, from: data) {
            excluded = list
        } else {
            excluded = ExcludedApp.defaults
        }
    }

    var limits: Limits { Limits(maxCount: maxCount, maxDays: maxDays) }

    func isExcluded(_ bundleID: String?) -> ExcludedApp? {
        guard let id = bundleID else { return nil }
        return excluded.first { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }
    }
}

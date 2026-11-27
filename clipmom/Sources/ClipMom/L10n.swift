import Foundation
import SwiftUI

/// Язык интерфейса — тот, что macOS выбрала для приложения (переводы в Resources/<язык>.lproj; ключ — русский текст).
enum L10n {
    /// Язык, который macOS выбрала для приложения (ru, если перевода нет).
    static let language = Bundle.main.preferredLocalizations.first ?? "ru"
    static let locale = Locale(identifier: language + (Locale.current.region.map { "_" + $0.identifier } ?? ""))
    /// SwiftUI на macOS сам не зеркалит интерфейс для арабского — задаём направление явно.
    static let layoutDirection: LayoutDirection =
        Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
}

extension View {
    /// Язык и направление письма приложения — в корень каждой сцены и панели.
    func appLocale() -> some View {
        environment(\.locale, L10n.locale).environment(\.layoutDirection, L10n.layoutDirection)
    }
}

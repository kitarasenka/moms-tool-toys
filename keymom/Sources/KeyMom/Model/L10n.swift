import SwiftUI

/// Язык интерфейса. Переводы — Resources/<язык>.lproj (ключ — русский текст), язык выбирает macOS.
enum L10n {
    /// Язык, который macOS выбрала для приложения (ru, если перевода нет).
    static let language = Bundle.main.preferredLocalizations.first ?? "ru"
    static let locale = Locale(identifier: language + (Locale.current.region.map { "_" + $0.identifier } ?? ""))
    /// SwiftUI на macOS сам не зеркалит интерфейс для арабского — задаём направление явно.
    static let layoutDirection: LayoutDirection =
        Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
}

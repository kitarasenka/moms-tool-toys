import Foundation
import SwiftUI

/// Язык интерфейса — его выбирает macOS (системный язык или язык BatteryMom в «Язык и регион»);
/// переводы лежат в Resources/<язык>.lproj, ключи — русский текст из кода.
enum L10n {
    /// Язык, который macOS выбрала для приложения (ru, если перевода нет).
    static let language = Bundle.main.preferredLocalizations.first ?? "ru"
    static let locale = Locale(identifier: language + (Locale.current.region.map { "_" + $0.identifier } ?? ""))
    /// SwiftUI на macOS сам не зеркалит интерфейс для арабского — задаём направление явно.
    static let layoutDirection: LayoutDirection =
        Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
}

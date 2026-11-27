import Foundation
import SwiftUI

/// Язык приложения. Выбирает macOS по `Resources/<язык>.lproj` (системный язык или язык DesktopMom
/// в «Язык и регион»); нет подходящего перевода — русский. `swift run` (без .lproj) — тоже русский.
enum L10n {
    static let language: String = {
        let own = Bundle.main.localizations.filter { $0 != "Base" }
        return own.isEmpty ? "ru" : (Bundle.main.preferredLocalizations.first ?? "ru")
    }()

    static let locale = Locale(identifier: language + (Locale.current.region.map { "_" + $0.identifier } ?? ""))

    /// SwiftUI на macOS сам не зеркалит интерфейс для арабского — задаём направление явно.
    static let layoutDirection: LayoutDirection =
        Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight

    static var isRussian: Bool { language.hasPrefix("ru") }
}

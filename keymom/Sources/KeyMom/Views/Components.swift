import AppKit
import SwiftUI

// MARK: - Фирменные цвета (как у иконок Mom's Tool Toys: синий с бирюзовым свечением)

enum Brand {
    static let blue = Color(red: 0.07, green: 0.42, blue: 0.93)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 1.00)
    static let yellow = Color(red: 1.00, green: 0.80, blue: 0.16)
    static let gradient = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Клавиша на картинке: «⌘ command», «Пробел».
struct KeyCap: View {
    let symbol: String
    var name: String?
    var wide = false
    var size: CGFloat = 1

    var body: some View {
        VStack(alignment: name == nil ? .center : .leading, spacing: 2 * size) {
            Text(symbol).font(.system(size: 20 * size, weight: .medium, design: .rounded))
            if let name { Text(name).font(.system(size: 10 * size)).foregroundStyle(.secondary) }
        }
        .frame(minWidth: (wide ? 150 : 52) * size, minHeight: 50 * size, alignment: name == nil ? .center : .bottomLeading)
        .padding(.horizontal, 8 * size)
        .padding(.vertical, 5 * size)
        .background(
            RoundedRectangle(cornerRadius: 8 * size, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.22), radius: 0, y: 2.5 * size)
        )
        .overlay(RoundedRectangle(cornerRadius: 8 * size, style: .continuous).strokeBorder(.separator))
    }
}

/// Сочетание клавишами: ⇧ + ⌘ + Пробел.
struct HotkeyKeys: View {
    let preset: HotkeyPreset
    var size: CGFloat = 1

    var body: some View {
        HStack(spacing: 6 * size) {
            ForEach(Array(zip(preset.symbols, preset.keyNames)), id: \.0) { sym, name in
                KeyCap(symbol: sym, name: name, size: size)
                Text("+").font(.system(size: 16 * size, weight: .semibold)).foregroundStyle(.secondary)
            }
            KeyCap(symbol: "Пробел", wide: true, size: size)
        }
    }
}

/// Карточка «нужен Универсальный доступ».
struct PermissionCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if !state.axTrusted && !state.demo {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(.orange).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Разрешите KeyMom исправлять текст в других приложениях").font(.headline)
                    Text("Чтобы заменить слово там, где вы печатаете, KeyMom нужен «Универсальный доступ». Откройте «Системные настройки → Конфиденциальность и безопасность → Универсальный доступ» и включите KeyMom. Индикатор раскладки, Caps Lock и раздел «Исправить текст» работают и без этого.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Разрешить…") { state.askTrust() }
                        Button("Открыть настройки") { Accessibility.openSettings() }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
        }
    }
}

extension View {
    /// Жёстко вписывает экран в доступное место. Без этого стопка со списками внутри колонки
    /// NavigationSplitView получает неограниченную высоту, и окно «разъезжается» (содержимое уходит за края).
    func fillAvailable() -> some View {
        GeometryReader { geo in self.frame(width: geo.size.width, height: geo.size.height) }
    }
}

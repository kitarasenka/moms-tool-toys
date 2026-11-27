import AppKit
import SwiftUI

// MARK: - Фирменные цвета (как у иконок Mom's Tool Toys: синий с бирюзовым свечением)

enum Brand {
    static let blue = Color(red: 0.07, green: 0.42, blue: 0.93)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 1.00)
    static let yellow = Color(red: 1.00, green: 0.80, blue: 0.16)
    static let gradient = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Level {
    var color: Color {
        switch self {
        case .ok: Color(red: 0.16, green: 0.70, blue: 0.36)
        case .warn: .orange
        case .danger: .red
        case .unknown: .gray
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var shield: String {
        switch self {
        case .ok: "checkmark.shield.fill"
        case .warn: "exclamationmark.shield.fill"
        case .danger: "xmark.shield.fill"
        case .unknown: "questionmark.diamond.fill"
        }
    }
}

/// Капсульная кнопка с градиентом и свечением.
struct GlowCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(enabled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.gray.opacity(0.45))))
            .shadow(color: Brand.cyan.opacity(enabled ? (configuration.isPressed ? 0.25 : 0.5) : 0), radius: configuration.isPressed ? 4 : 9)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct Card<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary)
                if let tint { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.07)) }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.map { AnyShapeStyle($0.opacity(0.35)) } ?? AnyShapeStyle(.separator.opacity(0.6))))
    }
}

/// Цветная капсула со статусом.
struct LevelBadge: View {
    let text: String
    let level: Level

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.symbol).font(.caption)
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(level.color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(level.color.opacity(0.12), in: Capsule())
    }
}

/// Небольшая метка (права расширения и т. п.).
struct Chip: View {
    let text: String
    var risky = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(risky ? Color.orange : Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((risky ? Color.orange : Color.gray).opacity(0.12), in: Capsule())
    }
}

/// Значок проверки в цветном квадрате.
struct LevelIcon: View {
    let icon: String
    let level: Level
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(level.color.opacity(0.14))
            Image(systemName: icon).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(level.color)
        }
        .frame(width: size, height: size)
    }
}

/// Заголовок карточки раздела: значок, название, статус справа.
struct SectionHeader: View {
    let icon: String
    let title: String
    let level: Level
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            LevelIcon(icon: icon, level: level, size: 32)
            Text(title).font(.headline)
            Spacer()
            LevelBadge(text: status, level: level)
        }
    }
}

struct LoadingView: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Плашка «дайте полный доступ к диску».
struct FullDiskAccessBanner: View {
    @Environment(AppState.self) private var state
    var reason: String

    var body: some View {
        if !state.fullDiskAccess && !state.demo {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Для полной проверки нужен полный доступ к диску").font(.headline)
                    Text("\(reason) Включите SafetyMom в «Полном доступе к диску» — при возвращении в окно всё перечитается само.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Открыть настройки") { FullDiskAccess.openSettings() }
            }
            .padding(12)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.orange.opacity(0.35)))
        }
    }
}

/// Сообщение о результате действия с крестиком.
struct MessageBar: View {
    let text: String
    var isError = false
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Level.ok.color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background((isError ? Color.orange : Level.ok.color).opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct AppIconView: View {
    let bundleID: String
    var fallback = "globe"
    var size: CGFloat = 28

    var body: some View {
        if let img = Apps.icon(bundleID) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: fallback).font(.system(size: size * 0.7)).foregroundStyle(Brand.gradient).frame(width: size, height: size)
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

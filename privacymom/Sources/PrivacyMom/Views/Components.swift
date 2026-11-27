import AppKit
import SwiftUI

// MARK: - Фирменные цвета (как у иконок Mom's Tool Toys: синий с бирюзовым свечением)

enum Brand {
    static let blue = Color(red: 0.07, green: 0.42, blue: 0.93)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 1.00)
    static let yellow = Color(red: 1.00, green: 0.80, blue: 0.16)
    static let gradient = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Большая круглая кнопка с градиентом и свечением — главное действие экрана.
struct GlowButtonStyle: ButtonStyle {
    var diameter: CGFloat = 150

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Brand.gradient))
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
            .shadow(color: Brand.cyan.opacity(configuration.isPressed ? 0.3 : 0.6), radius: configuration.isPressed ? 10 : 22)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Плашка «дайте полный доступ к диску».
struct FullDiskAccessBanner: View {
    @Environment(AppState.self) private var state
    var reason = String(localized: "Базы разрешений и данные Safari закрыты системой.")

    var body: some View {
        if !state.fullDiskAccess {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Нужен полный доступ к диску").font(.headline)
                    Text("\(reason) Включите PrivacyMom в «Полном доступе к диску» — при возвращении в окно всё перечитается само.")
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

/// Иконка файла или приложения из Finder.
struct FileIcon: View {
    let url: URL
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// Иконка приложения, а если его не нашли — общий значок программы.
struct AppIconView: View {
    let url: URL?
    var size: CGFloat = 22

    var body: some View {
        if let url {
            FileIcon(url: url, size: size)
        } else {
            Image(systemName: "app.dashed").font(.system(size: size * 0.8)).foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// Плитка «число + подпись».
struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color = Brand.blue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint == Brand.blue ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(tint)))
                .shadow(color: (tint == Brand.blue ? Brand.cyan : tint).opacity(0.45), radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Цветная метка-капсула.
struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.13), in: Capsule())
    }
}

/// Пустое состояние с крупной иконкой и действием.
struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Brand.gradient)
            Text(title).font(.title2.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            actions.padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Сообщение о результате действия, с крестиком.
struct MessageBar: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Brand.blue)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .padding(10)
        .background(Brand.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

extension View {
    /// Жёстко вписывает экран в доступное место. Без этого стопка со списками внутри детали
    /// NavigationSplitView получает неограниченную высоту, и окно «разъезжается» (содержимое уходит за края).
    func fillAvailable() -> some View {
        GeometryReader { geo in self.frame(width: geo.size.width, height: geo.size.height) }
    }
}

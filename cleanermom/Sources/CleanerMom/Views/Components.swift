import AppKit
import SwiftUI

// MARK: - Фирменные цвета (как у иконок Mom's Tool Toys: синий с бирюзовым свечением, жёлтая щётка)

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
            .font(.system(size: 20, weight: .semibold, design: .rounded))
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

/// Флажок с тремя состояниями: отмечено / частично / нет.
struct TriCheckbox: View {
    let state: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == true ? "checkmark.square.fill" : (state == nil ? "minus.square.fill" : "square"))
                .font(.system(size: 16))
                .foregroundStyle(state == false ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.blue))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == true ? "Отмечено" : (state == nil ? "Отмечено частично" : "Не отмечено"))
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
    var reason = "Часть папок (Почта, Корзина, данные других приложений) закрыта системой."

    var body: some View {
        if !state.fullDiskAccess {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Нужен полный доступ к диску").font(.headline)
                    Text("\(reason) Включите CleanerMom в «Полном доступе к диску», затем перезапустите его.")
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

/// Индикатор занятого места на диске.
struct DiskGauge: View {
    let disk: DiskInfo

    var body: some View {
        let frac = disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Macintosh HD", systemImage: "internaldrive").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
            ProgressView(value: frac)
                .tint(frac > 0.9 ? .red : (frac > 0.75 ? .orange : Brand.blue))
                .controlSize(.small)
            Text("Свободно \(Fmt.bytes(disk.available)) из \(Fmt.bytes(disk.total))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            actions.padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Корзина без полного доступа к диску: размер не узнать, но Finder может её очистить.
struct FinderTrashCard: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    var body: some View {
        let junk = state.junk
        Card {
            HStack(spacing: 12) {
                Image(systemName: "trash").font(.system(size: 22)).foregroundStyle(Brand.gradient).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Корзина").font(.headline)
                    Text(junk.finderTrashMessage ?? "Размер не виден без полного доступа к диску, но очистить её можно через Finder.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Очистить Корзину…") { confirm = true }
            }
        }
        .confirmationDialog("Очистить Корзину?", isPresented: $confirm) {
            Button("Очистить", role: .destructive) { Task { await junk.emptyTrashViaFinder(); state.refreshSystem() } }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text("Файлы из Корзины удалятся окончательно. macOS может спросить, разрешить ли CleanerMom управлять Finder.")
        }
    }
}

extension View {
    /// Жёстко вписывает экран в доступное место. Без этого стопка со списками внутри детали
    /// NavigationSplitView получает неограниченную высоту, и окно «разъезжается» (содержимое уходит за края).
    func fillAvailable() -> some View {
        GeometryReader { geo in self.frame(width: geo.size.width, height: geo.size.height) }
    }
}

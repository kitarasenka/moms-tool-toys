import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - Фирменные цвета (как у иконок Mom's Tool Toys: синий с бирюзовым свечением)

enum Brand {
    static let blue = Color(red: 0.07, green: 0.42, blue: 0.93)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 1.00)
    static let yellow = Color(red: 1.00, green: 0.80, blue: 0.16)
    static let gradient = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let barGradient = LinearGradient(colors: [blue, cyan], startPoint: .leading, endPoint: .trailing)
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

/// Флажок для строк списка.
struct Checkbox: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundStyle(on ? AnyShapeStyle(Brand.blue) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? String(localized: "Отмечено") : String(localized: "Не отмечено"))
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
    var reason = String(localized: "Часть папок закрыта системой.")

    var body: some View {
        if !state.fullDiskAccess {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Нужен полный доступ к диску").font(.headline)
                    Text("\(reason) Включите DiskMom в «Полном доступе к диску», затем перезапустите его.")
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

/// Иконка файла или папки из Finder.
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

/// Миниатюра содержимого (Quick Look), пока грузится — иконка Finder.
struct ThumbnailView: View {
    let url: URL
    var size: CGFloat = 44
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                FileIcon(url: url, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: url) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                image = rep.nsImage
            }
        }
    }
}

/// Полоска доли: синий градиент на сером фоне.
struct SizeBar: View {
    let fraction: Double
    var color: Color?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Brand.barGradient))
                    .frame(width: max(fraction > 0 ? 2 : 0, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Индикатор занятого места на загрузочном диске (низ боковой панели).
struct DiskGauge: View {
    let disk: DiskInfo

    var body: some View {
        let frac = disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0
        VStack(alignment: .leading, spacing: 5) {
            Label(DiskScanner.volumeName("/") ?? "Macintosh HD", systemImage: "internaldrive")
                .font(.caption).foregroundStyle(.secondary)
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

/// Экран «идёт работа»: кольцо, заголовок, подробности, кнопка «Остановить».
struct ProgressScreen: View {
    let title: String
    let detail: String
    var current: String?
    var value: Double?
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Brand.blue.opacity(0.15), lineWidth: 10)
                if let value {
                    Circle().trim(from: 0, to: value)
                        .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut, value: value)
                } else {
                    SpinningArc()
                }
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 92, height: 92)
            }
            .frame(width: 150, height: 150)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).monospacedDigit()
            if let current {
                Text(current).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            }
            Button("Остановить", action: onCancel).controlSize(.large).padding(.top, 4)
                .keyboardShortcut(.cancelAction)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Прокручиваемый экран, содержимое которого по центру, пока помещается. Высота жёстко
/// ограничена окном — длинная стопка не «разъезжает» NavigationSplitView.
struct CenteredScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content.frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Бегущая дуга для работы без известного конца.
struct SpinningArc: View {
    @State private var spin = false

    var body: some View {
        Circle().trim(from: 0, to: 0.22)
            .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

extension View {
    /// Жёстко вписывает экран в доступное место. Без этого стопка со списками внутри детали
    /// NavigationSplitView получает неограниченную высоту, и окно «разъезжается» (содержимое уходит за края).
    func fillAvailable() -> some View {
        GeometryReader { geo in self.frame(width: geo.size.width, height: geo.size.height) }
    }
}

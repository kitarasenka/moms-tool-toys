import AppKit
import SwiftUI

// MARK: - Фирменные цвета (как у иконок Mom's Tool Toys: синий с бирюзовым свечением)

enum Brand {
    static let blue = Color(red: 0.07, green: 0.42, blue: 0.93)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 1.00)
    static let yellow = Color(red: 1.00, green: 0.80, blue: 0.16)
    static let gradient = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
}

enum Fmt {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()

    static func ago(_ d: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(d) < 60 { return "только что" }
        return relative.localizedString(for: d, relativeTo: now)
    }

    static func bytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(n))
    }

    static func dateTime(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.wide).hour().minute().locale(Locale(identifier: "ru_RU")))
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

/// Значок записи: миниатюра картинки, иконка файла или символ на фирменном градиенте.
struct ClipIcon: View {
    @Environment(AppState.self) private var state
    let item: ClipItem
    var size: CGFloat = 34

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        Group {
            if item.kind == .image, let img = ImageCache.image(item.thumb ?? item.image, store: state.store) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else if item.kind == .files, let first = item.files?.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first)).resizable().padding(size * 0.06)
            } else {
                ZStack {
                    shape.fill(Brand.gradient)
                    Image(systemName: item.kind.icon)
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

/// Иконка приложения-источника (или пустое место того же размера).
struct SourceIcon: View {
    let bundleID: String?
    var size: CGFloat = 14

    var body: some View {
        if let img = AppIcons.icon(for: bundleID) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        }
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
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(Brand.gradient)
            Text(title).font(.title2.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            actions.padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, text: String) {
        self.init(icon: icon, title: title, text: text) { EmptyView() }
    }
}

/// Карточка про доступ к буферу обмена (macOS 15.4+ / 26: «Вставка из других приложений»).
struct PasteAccessCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let access = state.access
        let show = access == .ask || access == .denied || (access == .notAsked && !state.prefs.onboardingDismissed)
        if show {
            let warn = access != .notAsked
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: warn ? "hand.raised.fill" : "list.clipboard")
                    .font(.title2)
                    .foregroundStyle(warn ? AnyShapeStyle(.orange) : AnyShapeStyle(Brand.gradient))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(access)).font(.headline)
                    Text(text(access))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Открыть настройки") { PasteAccess.openSettings() }
                        Button("Проверить снова") { state.refreshAccess() }
                        if access == .notAsked {
                            Button("Понятно") { state.prefs.onboardingDismissed = true }
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background((warn ? Color.orange : Brand.cyan).opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((warn ? Color.orange : Brand.blue).opacity(0.35)))
        }
    }

    private func title(_ a: PasteAccess) -> String {
        switch a {
        case .denied: "ClipMom не может читать буфер обмена"
        case .ask: "macOS спрашивает разрешение при каждом копировании"
        default: "Разрешите ClipMom читать буфер обмена"
        }
    }

    private func text(_ a: PasteAccess) -> String {
        let how = "Откройте «Системные настройки → Конфиденциальность и безопасность → Вставка из других приложений» и выберите для ClipMom «Разрешить»."
        switch a {
        case .denied: return "Доступ запрещён, поэтому история не пополняется. " + how
        case .ask: return "Чтобы не отвечать на запрос каждый раз, ClipMom пока не записывает буфер сам. " + how
        default: return "Новые версии macOS могут один раз спросить, можно ли ClipMom читать скопированное. Нажмите «Разрешить», а лучше сразу: " + how
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

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Фирменные цвета (как у иконок Mom's Tool Toys: синий с бирюзовым свечением)

enum Brand {
    static let blue = Color(red: 0.07, green: 0.42, blue: 0.93)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 1.00)
    static let gradient = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Иконка файла: настоящая из Finder, а если файла нет (демо) — по типу.
struct FileIcon: View {
    let entry: Entry
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: FileIcons.icon(entry))
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
    }
}

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ e: Entry) -> NSImage {
        if Paths.exists(e.url) { return NSWorkspace.shared.icon(forFile: e.url.path) }
        let key = e.isFolder ? "/folder" : e.url.pathExtension.lowercased()
        if let i = cache[key] { return i }
        let type: UTType = e.isFolder ? .folder : (UTType(filenameExtension: key) ?? .data)
        let img = NSWorkspace.shared.icon(for: type)
        cache[key] = img
        return img
    }
}

/// Сводная плитка: крупное число и подпись.
struct StatTile: View {
    let value: String
    let label: String
    var icon: String
    var tint: Color = Brand.blue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
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

/// macOS не дала доступ к папке — объясняем, где включить.
struct AccessDeniedView: View {
    let folder: String
    let retry: () -> Void

    var body: some View {
        EmptyStateView(icon: "lock.shield", title: "Нет доступа к папке «\(folder)»",
                       text: "macOS не разрешила DesktopMom заглянуть в эту папку. Откройте «Системные настройки → Конфиденциальность и безопасность → Файлы и папки» и включите для DesktopMom «\(folder)».") {
            HStack {
                Button("Открыть настройки") { AppState.openFilesAndFoldersSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Проверить снова", action: retry)
            }
        }
    }
}

/// Полоса с итогом последнего действия.
struct BannerView: View {
    @Environment(AppState.self) private var state
    let banner: Banner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Color.orange : Color.green)
            Text(banner.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if banner.showJournal {
                Button("Журнал") { state.pane = .journal; state.banner = nil }.controlSize(.small)
            }
            Button { state.banner = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Скрыть")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background((banner.isError ? Color.orange : Color.green).opacity(0.12))
    }
}

/// Маленькая метка-капсула рядом с именем файла.
struct Tag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

extension View {
    /// Жёстко вписывает экран в доступное место. Без этого стопка со списками внутри колонки
    /// NavigationSplitView получает неограниченную высоту, и окно «разъезжается» (содержимое уходит за края).
    func fillAvailable() -> some View {
        GeometryReader { geo in self.frame(width: geo.size.width, height: geo.size.height) }
    }
}

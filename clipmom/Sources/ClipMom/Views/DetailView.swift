import AppKit
import SwiftUI

/// Правая колонка: карточка доступа к буферу, просмотр выбранной записи и действия.
struct DetailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            PasteAccessCard().padding([.horizontal, .top], 14)
            if let item = state.selectedItem {
                ItemDetail(item: item)
            } else {
                EmptyStateView(icon: "hand.point.left", title: "Выберите запись",
                               text: "Двойной щелчок или кнопка «Скопировать» вернёт её в буфер обмена. Из любого приложения — ⇧⌘V.")
            }
        }
        .fillAvailable()
    }
}

struct ItemDetail: View {
    @Environment(AppState.self) private var state
    let item: ClipItem

    var body: some View {
        VStack(spacing: 0) {
            header.padding(14)
            Divider()
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            actions.padding(12)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ClipIcon(item: item, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.kind.title + (item.pinned ? " · закреплено" : "")).font(.headline)
                HStack(spacing: 5) {
                    SourceIcon(bundleID: item.sourceID, size: 14)
                    Text(meta).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let s = item.sourceName { parts.append(s) }
        parts.append(Fmt.dateTime(item.date))
        parts.append(Fmt.bytes(item.bytes))
        if item.copies > 1 { parts.append("копировали \(item.copies) раз") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .text, .link:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let u = item.url {
                        Button { NSWorkspace.shared.open(u) } label: {
                            Label(u.host ?? u.absoluteString, systemImage: "safari")
                        }
                        .buttonStyle(.link)
                    }
                    Text(item.text ?? "")
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
        case .image:
            if let img = ImageCache.image(item.image, store: state.store) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(20)
            } else {
                EmptyStateView(icon: "photo.badge.exclamationmark", title: "Картинка не найдена",
                               text: "Файл картинки удалён из папки ClipMom.")
            }
        case .files:
            List(item.files ?? [], id: \.self) { path in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((path as NSString).lastPathComponent)
                        Text((path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if FileManager.default.fileExists(atPath: path) {
                        Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            .controlSize(.small)
                    } else {
                        Text("файла нет").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { state.copy(item) } label: {
                Label("Скопировать", systemImage: "doc.on.doc")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.blue)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Вернуть в буфер обмена (⌘↩)")

            Button { state.togglePin(item) } label: {
                Label(item.pinned ? "Открепить" : "Закрепить", systemImage: item.pinned ? "pin.slash" : "pin")
            }
            .help("Закреплённое не удаляется по сроку и лимиту")

            Spacer()
            Button(role: .destructive) { state.delete(item) } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
        .controlSize(.large)
    }
}

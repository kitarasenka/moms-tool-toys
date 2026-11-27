import SwiftUI

struct JournalView: View {
    @Environment(AppState.self) private var state
    @State private var confirmClear = false

    var body: some View {
        let list = state.journalEntries
        Group {
            if list.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", title: String(localized: "Журнал пуст"),
                               text: String(localized: "Здесь появится всё, что DesktopMom переложил или отправил в Корзину, — с кнопкой «Вернуть»."))
            } else {
                List {
                    ForEach(list) { e in JournalRow(entry: e) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("Журнал")
        .navigationSubtitle(list.isEmpty ? "" : String(localized: "\(list.count) записей"))
        .toolbar {
            ToolbarItem {
                Button("Очистить журнал") { confirmClear = true }.disabled(list.isEmpty)
            }
        }
        .confirmationDialog("Очистить журнал?", isPresented: $confirmClear) {
            Button("Очистить", role: .destructive) { state.clearJournal() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сами файлы останутся где лежат, но кнопки «Вернуть» пропадут.")
        }
    }
}

struct JournalRow: View {
    @Environment(AppState.self) private var state
    let entry: LogEntry

    var body: some View {
        let from = URL(fileURLWithPath: entry.from).deletingLastPathComponent()
        let to = entry.to.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        HStack(spacing: 12) {
            Image(systemName: entry.action == .trashed ? "trash" : "arrow.right.doc.on.clipboard")
                .font(.title3)
                .foregroundStyle(entry.action == .trashed ? AnyShapeStyle(.orange) : AnyShapeStyle(Brand.gradient))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Text(entry.action == .trashed
                     ? String(localized: "\(state.pretty(from)) → Корзина")
                     : "\(state.pretty(from)) → \(to.map(state.pretty) ?? "?")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Fmt.dateTime(entry.date)).font(.caption).foregroundStyle(.secondary)
            if entry.undone {
                Tag(text: String(localized: "возвращено"), tint: .green)
            } else {
                Button("Вернуть") { state.undo(entry) }
                    .disabled(!state.canUndo(entry))
                    .help(state.canUndo(entry) ? String(localized: "Положить обратно, откуда взяли")
                                               : String(localized: "Файла уже нет на новом месте или старое место занято"))
            }
            Button { state.reveal(entry) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help(entry.action == .trashed && !entry.undone ? String(localized: "Показать в Корзине")
                                                                : String(localized: "Показать в Finder"))
        }
        .padding(.vertical, 2)
    }
}

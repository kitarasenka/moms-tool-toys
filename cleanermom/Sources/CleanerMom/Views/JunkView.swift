import SwiftUI

struct JunkView: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    var body: some View {
        let junk = state.junk
        Group {
            switch junk.phase {
            case .idle:
                EmptyStateView(icon: "trash.circle", title: "Мусор ещё не искали",
                               text: "Сканирование только смотрит и считает — ничего не удаляется без вашего подтверждения.") {
                    Button("Сканировать") { Task { await junk.scan() } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            case .scanning, .cleaning:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(junk.phase == .scanning ? "Ищу мусор…" : "Очищаю… \(junk.cleanedCount) из \(junk.cleaningTotal)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready, .done:
                content.fillAvailable()
            }
        }
        .navigationTitle("Мусор")
        .toolbar {
            ToolbarItem {
                Button { Task { await junk.scan() } } label: { Label("Сканировать заново", systemImage: "arrow.clockwise") }
                    .disabled(junk.phase == .scanning || junk.phase == .cleaning)
                    .help("Сканировать заново (⌘R)")
            }
        }
        .confirmationDialog("Очистить \(Fmt.bytes(junk.totalSelected))?", isPresented: $confirm) {
            Button("Очистить", role: .destructive) { Task { await junk.clean(); state.refreshSystem() } }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text(CleanText.confirmation(junk))
        }
    }

    private var content: some View {
        let junk = state.junk
        return VStack(spacing: 0) {
            if !junk.denied.isEmpty {
                FullDiskAccessBanner().padding([.horizontal, .top], 12)
            }
            // HStack, а не HSplitView: тот берёт «идеальную» высоту списков и раздувает окно.
            HStack(spacing: 0) {
                categoryList.frame(width: 330)
                Divider()
                itemList.frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                if let r = junk.report, junk.phase == .done {
                    Label("Освобождено \(Fmt.bytes(r.freed))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Text("Отмечено: \(Fmt.count(junk.selectedCount, "объект", "объекта", "объектов")), \(Fmt.bytes(junk.totalSelected))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button("Очистить") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(junk.selectedCount == 0)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private var categoryList: some View {
        let junk = state.junk
        let focus = Binding<String?>(get: { junk.focusedCategory }, set: { junk.focusedCategory = $0 })
        return List(selection: focus) {
            ForEach(JunkGroup.allCases) { group in
                let cats = junk.categories.filter { $0.group == group }
                Section(group.rawValue) {
                    ForEach(cats) { c in
                        HStack(spacing: 8) {
                            TriCheckbox(state: junk.state(c)) { junk.toggle(c) }
                                .disabled(junk.items(c).isEmpty)
                            Image(systemName: c.icon).foregroundStyle(Brand.blue).frame(width: 20)
                            Text(c.title).lineLimit(1)
                            Spacer()
                            Text(junk.items(c).isEmpty ? "—" : Fmt.bytes(junk.total(c)))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .opacity(junk.items(c).isEmpty ? 0.5 : 1)
                        .tag(c.id)
                    }
                }
            }
        }
    }

    @ViewBuilder private var itemList: some View {
        let junk = state.junk
        if let c = junk.categories.first(where: { $0.id == junk.focusedCategory }) {
            let items = junk.items(c)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: c.icon).font(.title2).foregroundStyle(Brand.gradient)
                        Text(c.title).font(.title2.weight(.semibold))
                        Spacer()
                        Text(Fmt.bytes(junk.selectedSize(c)) + " из " + Fmt.bytes(junk.total(c)))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(c.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if c.mode == .trash {
                        Label("Объекты переносятся в Корзину", systemImage: "arrow.uturn.backward.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                Divider()
                if items.isEmpty, c.id == "trash", junk.trashDenied {
                    FinderTrashCard().padding(14)
                    Spacer()
                } else if items.isEmpty {
                    Text(junk.results[c.id]?.denied.isEmpty == false ? "Нет доступа к папке — нужен полный доступ к диску."
                                                                      : "Здесь ничего не нашлось.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                ItemRow(item: item).padding(.horizontal, 14).padding(.vertical, 4)
                                Divider().padding(.leading, 76)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        } else {
            Text("Выберите категорию слева").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ItemRow: View {
    @Environment(AppState.self) private var state
    let item: JunkItem

    var body: some View {
        let junk = state.junk
        HStack(spacing: 10) {
            TriCheckbox(state: junk.selected.contains(item.id)) { junk.toggle(item) }
            FileIcon(url: item.url, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(item.subtitle ?? Paths.pretty(item.url))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let note = item.note {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(Fmt.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Показать в Finder") { Paths.reveal(item.url) }
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }
}

import SwiftUI

struct LargeFilesView: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    private let sizes: [(Int64, String)] = [
        (20_000_000, String(localized: "от 20 МБ")), (50_000_000, String(localized: "от 50 МБ")), (100_000_000, String(localized: "от 100 МБ")),
        (500_000_000, String(localized: "от 500 МБ")), (1_000_000_000, String(localized: "от 1 ГБ")),
    ]

    var body: some View {
        @Bindable var large = state.large
        Group {
            if large.scanning {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Просматриваю домашнюю папку… \(large.seen.formatted(.number.locale(L10n.locale))) файлов")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !large.scanned {
                EmptyStateView(icon: "doc.on.doc", title: String(localized: "Крупные и старые файлы"),
                               text: String(localized: "Найду большие файлы в домашней папке: забытые видео, образы дисков, архивы. Решаете вы — выбранное уйдёт в Корзину.")) {
                    Button("Найти крупные файлы") { Task { await large.scan() } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else {
                content.fillAvailable()
            }
        }
        .navigationTitle("Крупные файлы")
        .searchable(text: $large.search, placement: .toolbar, prompt: String(localized: "Имя или папка"))
        .toolbar {
            ToolbarItemGroup {
                Picker("Размер", selection: $large.minSize) {
                    ForEach(sizes, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.menu)
                .help("Минимальный размер")
                Picker("Возраст", selection: $large.age) {
                    ForEach(LargeFilesStore.Age.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Как давно файл менялся")
                Button { Task { await large.scan() } } label: { Label("Искать заново", systemImage: "arrow.clockwise") }
                    .disabled(large.scanning)
            }
        }
        .confirmationDialog("Перенести в Корзину \(Fmt.files(large.selectedFiles.count))?",
                            isPresented: $confirm) {
            Button("В Корзину", role: .destructive) { Task { await large.trashSelected(); state.refreshSystem() } }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text("\(Fmt.bytes(large.selectedFiles.reduce(0) { $0 + $1.size })). Файлы можно вернуть из Корзины, пока она не очищена.")
        }
    }

    private var content: some View {
        @Bindable var large = state.large
        let rows = large.visible
        return VStack(spacing: 0) {
            FullDiskAccessBanner(reason: String(localized: "Без него macOS может спрятать часть папок."))
                .padding([.horizontal, .top], 12)
            Table(rows, sortOrder: $large.sortOrder) {
                TableColumn("") { (f: LargeFile) in
                    TriCheckbox(state: large.selected.contains(f.id)) {
                        if large.selected.contains(f.id) { large.selected.remove(f.id) } else { large.selected.insert(f.id) }
                    }
                }
                .width(24)
                TableColumn(String(localized: "Имя"), value: \.name) { f in
                    HStack(spacing: 8) {
                        FileIcon(url: f.url, size: 18)
                        Text(f.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 200, ideal: 320)
                TableColumn(String(localized: "Папка"), value: \.folder) { f in
                    Text(f.folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .width(min: 140, ideal: 260)
                TableColumn(String(localized: "Размер"), value: \.size) { f in
                    Text(Fmt.bytes(f.size)).monospacedDigit()
                }
                .width(min: 80, ideal: 90)
                TableColumn(String(localized: "Изменён"), value: \.modified, comparator: OptionalDateComparator()) { f in
                    Text(Fmt.date(f.modified)).foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 110)
            }
            .contextMenu(forSelectionType: LargeFile.ID.self) { ids in
                if let id = ids.first, let f = large.files.first(where: { $0.id == id }) {
                    Button("Показать в Finder") { Paths.reveal(f.url) }
                    Button("Открыть") { NSWorkspace.shared.open(f.url) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let f = large.files.first(where: { $0.id == id }) { Paths.reveal(f.url) }
            }
            .overlay {
                if rows.isEmpty {
                    Text("Под условия ничего не подходит").foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                if let r = large.lastReport, !r.failures.isEmpty {
                    Label("Не удалось: \(r.failures.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).lineLimit(1)
                }
                Text("Показано: \(rows.count), \(Fmt.bytes(rows.reduce(0) { $0 + $1.size }))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                let sel = large.selectedFiles
                Text("Отмечено: \(sel.count), \(Fmt.bytes(sel.reduce(0) { $0 + $1.size }))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button("В Корзину") { confirm = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(sel.isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
    }
}

/// Сортировка по дате, где «нет даты» — самое старое.
struct OptionalDateComparator: SortComparator {
    var order: SortOrder = .forward
    func compare(_ a: Date?, _ b: Date?) -> ComparisonResult {
        let x = a ?? .distantPast, y = b ?? .distantPast
        let r: ComparisonResult = x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        return order == .forward ? r : (r == .orderedAscending ? .orderedDescending : (r == .orderedDescending ? .orderedAscending : r))
    }
}

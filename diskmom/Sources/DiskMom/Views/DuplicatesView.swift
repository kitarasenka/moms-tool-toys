import AppKit
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    static let sizes: [(Int64, String)] = [
        (100_000, String(localized: "от 100 КБ")), (1_000_000, String(localized: "от 1 МБ")), (10_000_000, String(localized: "от 10 МБ")),
        (100_000_000, String(localized: "от 100 МБ")), (1_000_000_000, String(localized: "от 1 ГБ")),
    ]

    var body: some View {
        let d = state.dupes
        Group {
            switch d.phase {
            case .idle: setup
            case .scanning:
                let p = d.progress
                ProgressScreen(title: String(localized: "Ищу дубликаты…"),
                               detail: p.total > 0 ? String(localized: "\(p.phase): \(p.done.formatted(.number.locale(L10n.locale))) из \(p.total.formatted(.number.locale(L10n.locale)))")
                                   : String(localized: "\(p.phase): \(Fmt.files(p.done))"),
                               value: p.total > 0 ? Double(p.done) / Double(p.total) : nil) { d.cancel() }
            case .ready: results.fillAvailable()
            }
        }
        .navigationTitle("Дубликаты")
        .toolbar {
            ToolbarItemGroup {
                if d.phase == .ready {
                    Menu {
                        Button("Оставить самый новый") { d.apply(.keepNewest) }
                        Button("Оставить самый старый") { d.apply(.keepOldest) }
                        Menu("Оставить копии в папке") {
                            ForEach(d.folders, id: \.self) { f in
                                Button(Paths.pretty(f)) { d.apply(.keepIn(f)) }
                            }
                        }
                        Divider()
                        Button("Снять все отметки") { d.selected = []; d.warning = nil }
                    } label: { Label("Автовыбор", systemImage: "wand.and.stars") }
                        .help("Какие копии отметить к удалению")
                    Button { d.phase = .idle } label: { Label("Папки и размер", systemImage: "slider.horizontal.3") }
                        .help("Изменить папки и минимальный размер")
                }
                Button { Task { await d.scan() } } label: { Label("Искать заново", systemImage: "arrow.clockwise") }
                    .help("Искать заново")
                    .disabled(d.phase == .scanning || d.folders.isEmpty)
            }
        }
        .confirmationDialog("Перенести в Корзину \(Fmt.files(d.toTrash.count))?", isPresented: $confirm) {
            Button("В Корзину", role: .destructive) { Task { await d.trashSelected(); state.refreshSystem() } }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text("Освободится \(Fmt.bytes(d.selectedSize)). В каждой группе останется хотя бы одна копия. Файлы можно вернуть из Корзины, пока она не очищена.")
        }
    }

    // MARK: Настройка

    private var setup: some View {
        @Bindable var d = state.dupes
        return CenteredScroll {
            VStack(spacing: 18) {
                Image(systemName: "doc.on.doc.fill").font(.system(size: 50)).foregroundStyle(Brand.gradient)
                Text("Дубликаты").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Найду одинаковые файлы — даже с разными именами. Сравниваю содержимое, а не названия. Медиатека «Фото» и другие пакеты не просматриваются.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Где искать").font(.headline)
                        ForEach(d.folders, id: \.self) { f in
                            HStack(spacing: 8) {
                                FileIcon(url: f, size: 20)
                                Text(Paths.pretty(f)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { d.folders.removeAll { $0 == f } } label: { Image(systemName: "minus.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .help("Убрать папку")
                            }
                        }
                        HStack {
                            Button("Добавить папку…") { d.addFolder() }
                            if d.folders != DupesStore.defaultFolders {
                                Button("Как было") { d.folders = DupesStore.defaultFolders }
                            }
                            Spacer()
                            Picker("Размер файла", selection: $d.minSize) {
                                ForEach(Self.sizes, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                    }
                }
                .frame(maxWidth: 560)
                Button("Найти\nдубликаты") { Task { await d.scan() } }
                    .buttonStyle(GlowButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(d.folders.isEmpty)
                    .padding(.top, 4)
            }
            .padding(30)
        }
    }

    // MARK: Результаты

    private var results: some View {
        let d = state.dupes
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(Fmt.bytes(d.totalReclaimable)).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                Text("можно освободить · групп: \(d.groups.count.formatted(.number.locale(L10n.locale))) · \(Fmt.seconds(d.elapsed))").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if d.groups.isEmpty {
                EmptyStateView(icon: "checkmark.seal", title: String(localized: "Дубликатов нет"),
                               text: String(localized: "В выбранных папках нет одинаковых файлов \(Self.sizes.first { $0.0 == d.minSize }?.1 ?? "").")) {
                    Button("Изменить папки") { d.phase = .idle }
                }
            } else {
                List {
                    ForEach(d.groups) { g in
                        Section { ForEach(g.files) { f in fileRow(f, g) } } header: { groupHeader(g) }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack(spacing: 12) {
                if let w = d.warning {
                    Label(w, systemImage: "hand.raised").foregroundStyle(.orange).lineLimit(1)
                } else if let r = d.report {
                    if r.failures.isEmpty {
                        Label("В Корзине: \(Fmt.files(r.trashed.count)), освобождено \(Fmt.bytes(r.freed))", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Label("Не удалось: \(r.failures.joined(separator: "; "))", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).lineLimit(1).help(r.failures.joined(separator: "\n"))
                    }
                }
                Spacer()
                Text("Отмечено: \(Fmt.files(d.toTrash.count)), \(Fmt.bytes(d.selectedSize))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button("В Корзину…") { confirm = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(d.toTrash.isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private func groupHeader(_ g: DupGroup) -> some View {
        HStack(spacing: 10) {
            ThumbnailView(url: g.files[0].url, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.name).font(.headline).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                Text("\(Fmt.copies(g.files.count)) по \(Fmt.bytes(g.size))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("лишнее: \(Fmt.bytes(g.reclaimable))").font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func fileRow(_ f: DupFile, _ g: DupGroup) -> some View {
        let d = state.dupes
        let on = d.selected.contains(f.id)
        return HStack(spacing: 10) {
            Checkbox(on: on) { d.toggle(f, in: g) }
            FileIcon(url: f.url, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(Paths.pretty(f.folder)).lineLimit(1).truncationMode(.middle)
                if f.name != g.name {
                    Text(f.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if !on { Text("остаётся").font(.caption).foregroundStyle(Brand.blue) }
            VStack(alignment: .trailing, spacing: 1) {
                Text("изменён \(Fmt.date(f.modified))").font(.caption).foregroundStyle(.secondary)
                Text("создан \(Fmt.date(f.created))").font(.caption).foregroundStyle(.tertiary)
            }
            .monospacedDigit()
            Button { Paths.reveal(f.url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Показать в Finder")
        }
        .opacity(on ? 0.75 : 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Показать в Finder") { Paths.reveal(f.url) }
            Button("Открыть") { NSWorkspace.shared.open(f.url) }
        }
    }
}

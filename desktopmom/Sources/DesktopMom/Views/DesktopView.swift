import SwiftUI

struct DesktopView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.desktopDenied {
                AccessDeniedView(folder: String(localized: "Рабочий стол")) { state.scanDesktop() }
            } else if !state.desktopScanned {
                ProgressView("Смотрю, что лежит на Рабочем столе…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    summary.padding(14)
                    Divider()
                    HStack(spacing: 0) {
                        FileGroupsList()
                        Divider()
                        ScrollView {
                            VStack(spacing: 12) {
                                ScreenshotsCard()
                                CaptureLocationCard()
                                TidyCard()
                            }
                            .padding(14)
                        }
                        .frame(width: 350)
                    }
                }
            }
        }
        .navigationTitle("Рабочий стол")
        .navigationSubtitle(state.desktopBusy ? String(localized: "обновляется…") : "")
    }

    private var summary: some View {
        let all = state.desktop
        let shots = state.entries(.screenshots)
        return HStack(spacing: 10) {
            StatTile(value: "\(all.count)", label: String(localized: "на Рабочем столе"), icon: "menubar.dock.rectangle")
            StatTile(value: "\(shots.count)", label: String(localized: "\(shots.count) снимков экрана (подпись)"),
                     icon: "camera.viewfinder", tint: shots.isEmpty ? .green : .orange)
            StatTile(value: Fmt.bytes(all.reduce(0) { $0 + $1.size }), label: String(localized: "занимает всё вместе"),
                     icon: "internaldrive")
        }
    }
}

/// Слева — всё, что лежит на столе, по группам.
struct FileGroupsList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let groups = DeskGroup.allCases.filter { !state.entries($0).isEmpty }
        if groups.isEmpty {
            EmptyStateView(icon: "sparkles", title: String(localized: "Рабочий стол чист"),
                           text: String(localized: "Здесь ничего не лежит — красота. Новые снимки экрана появятся тут, если не сохранять их в отдельную папку."))
        } else {
            List {
                ForEach(groups) { g in
                    let items = state.entries(g).sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
                    Section {
                        ForEach(items) { e in EntryRow(entry: e) }
                    } header: {
                        HStack {
                            Label(g.title, systemImage: g.icon)
                            Spacer()
                            Text("\(items.count) · \(Fmt.bytes(items.reduce(0) { $0 + $1.size }))")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
        }
    }
}

struct EntryRow: View {
    @Environment(AppState.self) private var state
    let entry: Entry

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(entry: entry)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            if entry.isSymlink { Tag(text: String(localized: "ссылка")) }
            Spacer(minLength: 8)
            Text(Fmt.date(entry.created)).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.bytes(entry.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .contextMenu {
            Button("Показать в Finder") { state.reveal(entry.url) }
        }
    }
}

// MARK: - Карточки справа

struct ScreenshotsCard: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    var body: some View {
        let shots = state.screenshots
        let plan = state.screenshotPlan
        Card {
            Label("Снимки экрана", systemImage: "camera.viewfinder").font(.headline)
            if shots.isEmpty {
                Text("На Рабочем столе нет снимков экрана.").foregroundStyle(.secondary)
            } else {
                let size = Fmt.bytes(shots.reduce(0) { $0 + $1.size })
                Text(String(localized: "\(shots.count) снимков и записей экрана, \(size).") + " "
                     + String(localized: "DesktopMom переложит их в папку по месяцам — ничего не удаляется."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(plan.prefix(4), id: \.month) { m in
                        Label("\(m.month) — \(m.count)", systemImage: "folder")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if plan.count > 4 {
                        Text(String(localized: "и ещё \(plan.count - 4) месяцев"))
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(Brand.blue)
                Text(state.pretty(state.screenshotsBase)).font(.caption).lineLimit(2)
                Spacer(minLength: 4)
                Button("Изменить…") { state.chooseScreenshotsBase() }.controlSize(.small)
            }
            .padding(.top, 2)
            Button {
                confirm = true
            } label: {
                Label("Разложить снимки экрана", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(shots.isEmpty || state.desktopBusy)
        }
        .confirmationDialog(String(localized: "Разложить \(shots.count) снимков экрана?"),
                            isPresented: $confirm) {
            Button("Разложить") { state.organizeScreenshots() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Файлы переедут в «\(state.pretty(state.screenshotsBase))», в папки по месяцам. Ничего не удаляется; вернуть можно в «Журнале».")
        }
    }
}

struct CaptureLocationCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Card {
            Label("Новые снимки экрана", systemImage: "camera.badge.ellipsis").font(.headline)
            Text("Сейчас сохраняются \(state.captureTitle).").font(.callout)
            if state.captureGoesToBase {
                Label("Уже сохраняются в папку снимков", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else {
                Button("Сохранять сразу в «Снимки экрана»") { state.saveNewScreenshotsToBase() }
            }
            if state.captureLocation != nil {
                Button("Вернуть на Рабочий стол") { state.resetScreenshotLocation() }.controlSize(.small)
            }
            Text("То же, что ⇧⌘5 → «Параметры» → «Сохранить в». Новые снимки лягут в эту папку целиком, без деления на месяцы.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TidyCard: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    var body: some View {
        let groups = DeskGroup.allCases.filter { $0 != .screenshots && !state.entries($0).isEmpty }
        let picked = state.tidyCandidates
        Card {
            Label("Остальное", systemImage: "archivebox").font(.headline)
            if groups.isEmpty {
                Text("Кроме снимков экрана, на столе ничего нет.").foregroundStyle(.secondary)
            } else {
                Text("Можно убрать со стола и остальное — по папкам в «\(state.pretty(state.roots.inbox))». Отметьте, что убрать:")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(groups) { g in
                    Toggle(isOn: Binding(get: { state.tidyGroups.contains(g) },
                                         set: { if $0 { state.tidyGroups.insert(g) } else { state.tidyGroups.remove(g) } })) {
                        HStack {
                            Text(g.title)
                            Spacer()
                            Text("\(state.entries(g).count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Button("Убрать отмеченное") { confirm = true }
                    .disabled(picked.isEmpty || state.desktopBusy)
            }
        }
        .confirmationDialog(String(localized: "Убрать со стола \(picked.count) объектов?"),
                            isPresented: $confirm) {
            Button("Убрать") { state.tidyOthers() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Они переедут в «\(state.pretty(state.roots.inbox))», каждая группа — в свою папку. Ничего не удаляется; вернуть можно в «Журнале».")
        }
    }
}

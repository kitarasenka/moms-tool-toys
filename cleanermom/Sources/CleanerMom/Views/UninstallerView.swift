import SwiftUI

struct UninstallerView: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    var body: some View {
        @Bindable var apps = state.apps
        HStack(spacing: 0) {
            appList.frame(width: 330)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fillAvailable()
        .navigationTitle("Деинсталлятор")
        .searchable(text: $apps.search, placement: .toolbar, prompt: "Приложение")
        .toolbar {
            ToolbarItem {
                Picker("Сортировка", selection: $apps.sortBySize) {
                    Text("По размеру").tag(true)
                    Text("По имени").tag(false)
                }
                .pickerStyle(.segmented)
            }
        }
        .task { if !apps.loaded { await apps.load() } }
        .confirmationDialog(confirmTitle, isPresented: $confirm) {
            Button("Удалить", role: .destructive) { Task { await apps.uninstall(); state.refreshSystem() } }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text("Приложение и отмеченные файлы перенесутся в Корзину.\(apps.isRunning ? " Приложение сейчас открыто — оно будет закрыто." : "")")
        }
        .alert("Деинсталлятор", isPresented: Binding(get: { apps.message != nil }, set: { if !$0 { apps.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(apps.message ?? "")
        }
    }

    private var confirmTitle: String {
        guard let a = state.apps.current else { return "" }
        return "Удалить \(a.name)?"
    }

    private var appList: some View {
        let apps = state.apps
        let sel = Binding<String?>(get: { apps.selection }, set: { id in Task { await apps.select(id) } })
        return List(apps.visible, selection: sel) { app in
            HStack(spacing: 10) {
                FileIcon(url: app.url, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).lineLimit(1)
                    Text(app.lastUsed.map { "открывалось \(Fmt.ago($0))" } ?? "нет данных о запуске")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let s = apps.sizes[app.id] {
                    Text(Fmt.bytes(s)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.vertical, 2)
            .tag(app.id)
        }
        .overlay { if apps.loading { ProgressView("Ищу приложения…") } }
    }

    @ViewBuilder private var detail: some View {
        let apps = state.apps
        if let app = apps.current {
            let appSize = apps.sizes[app.id] ?? 0
            let chosen = apps.leftovers.filter { apps.selectedLeftovers.contains($0.id) }
            let total = appSize + chosen.reduce(0) { $0 + max(0, $1.size) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    FileIcon(url: app.url, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title.weight(.semibold))
                        Text([app.version.isEmpty ? nil : "Версия \(app.version)", app.bundleID]
                            .compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        Text(Paths.pretty(app.url)).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(18)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Вместе с приложением").font(.headline)
                        Spacer()
                        if !apps.leftovers.isEmpty {
                            Button(apps.selectedLeftovers.count == apps.leftovers.count ? "Снять все" : "Отметить все") {
                                if apps.selectedLeftovers.count == apps.leftovers.count { apps.selectedLeftovers = [] }
                                else { apps.selectedLeftovers = Set(apps.leftovers.map(\.id)) }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    Text("Настройки, кэш и данные, которые приложение оставило в ~/Library. Если планируете поставить его снова и сохранить настройки — снимите галочки.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding([.horizontal, .top], 18)
                List {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary)
                        FileIcon(url: app.url, size: 20)
                        Text("\(app.name).app").lineLimit(1)
                        Spacer()
                        Text(apps.sizes[app.id].map(Fmt.bytes) ?? "…").monospacedDigit().foregroundStyle(.secondary)
                    }
                    ForEach(apps.leftovers) { l in
                        HStack(spacing: 10) {
                            TriCheckbox(state: apps.selectedLeftovers.contains(l.id)) {
                                if apps.selectedLeftovers.contains(l.id) { apps.selectedLeftovers.remove(l.id) }
                                else { apps.selectedLeftovers.insert(l.id) }
                            }
                            FileIcon(url: l.url, size: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.kind).lineLimit(1)
                                Text(Paths.pretty(l.url)).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(l.size < 0 ? "—" : Fmt.bytes(l.size)).monospacedDigit().foregroundStyle(.secondary)
                                .help(l.size < 0 ? "Размер виден только с полным доступом к диску" : "")
                        }
                        .contextMenu { Button("Показать в Finder") { Paths.reveal(l.url) } }
                    }
                }
                .listStyle(.inset)
                .overlay(alignment: .bottom) {
                    if apps.loadingLeftovers {
                        ProgressView("Ищу файлы приложения…").controlSize(.small).padding()
                    }
                }
                Divider()
                HStack {
                    if apps.isRunning {
                        Label("Приложение открыто", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
                    }
                    Spacer()
                    Text("Освободится \(Fmt.bytes(total))").foregroundStyle(.secondary).monospacedDigit()
                    Button("Удалить") { confirm = true }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                        .disabled(apps.working || apps.loadingLeftovers)
                }
                .padding(12)
                .background(.bar)
            }
        } else {
            EmptyStateView(icon: "xmark.app", title: "Удаление приложений",
                           text: "Выберите приложение слева: оно перенесётся в Корзину вместе с настройками, кэшем и данными, которые оставило в системе. Системные приложения Apple не показываются.") {
                EmptyView()
            }
        }
    }
}

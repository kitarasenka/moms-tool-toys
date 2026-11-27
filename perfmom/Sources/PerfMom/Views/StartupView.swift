import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum StartupTab: String, CaseIterable, Identifiable {
    case loginItems = "Открывать при входе"
    case jobs = "Фоновые агенты и службы"
    var id: Self { self }
}

enum JobFilter: String, CaseIterable, Identifiable {
    case autostart = "Автозапуск"
    case all = "Все"
    case disabled = "Выключенные"
    var id: Self { self }
}

struct StartupView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let store = state.startup
        Group {
            switch state.startupTab {
            case .jobs: LaunchJobsView()
            case .loginItems: LoginItemsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Раздел", selection: $state.startupTab) {
                    ForEach(StartupTab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Автозагрузка")
        .task {
            if !store.loadedOnce { await store.reloadJobs() }
            if store.loginAccess == .unknown { await store.refreshLoginItems() }
        }
        .alert("Не удалось выполнить действие",
               isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

// MARK: - Агенты и службы launchd

struct LaunchJobsView: View {
    @Environment(AppState.self) private var state
    @State private var filter: JobFilter = .autostart
    @State private var selection: String?
    @State private var pendingTrash: LaunchJob?

    var body: some View {
        let store = state.startup
        let q = state.search.trimmingCharacters(in: .whitespaces)
        let jobs = store.jobs.filter { job in
            let byFilter: Bool = switch filter {
            case .autostart: job.startsAutomatically
            case .all: true
            case .disabled: !job.enabled
            }
            return byFilter && (q.isEmpty || job.label.localizedCaseInsensitiveContains(q)
                || job.displayCommand.localizedCaseInsensitiveContains(q) || job.vendor.localizedCaseInsensitiveContains(q))
        }
        // Работающие системные службы находим по пути программы среди процессов.
        let pidByPath = Dictionary(state.monitor.processes.map { ($0.path, $0.pid) }, uniquingKeysWith: { a, _ in a })
        let pidByApp = Dictionary(state.monitor.processes.compactMap { p in PathTools.outermostApp(p.path).map { ($0, p.pid) } },
                                  uniquingKeysWith: { a, b in min(a, b) })
        let runningPID: (LaunchJob) -> pid_t? = { job in
            if let pid = job.pid { return pid }
            guard let target = job.target else { return nil }
            return target.hasSuffix(".app") ? pidByApp[target] : pidByPath[target]
        }

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Показывать", selection: $filter) {
                    ForEach(JobFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Text("Выключенные службы не запустятся и после перезагрузки. Системным службам нужен пароль администратора.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if store.loadingJobs { ProgressView().controlSize(.small) }
                Button {
                    Task { await store.reloadJobs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить список")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            Table(jobs, selection: $selection) {
                TableColumn(String(localized: "Вкл.")) { job in
                    JobToggle(job: job, store: state.startup)
                }
                .width(46)

                TableColumn(String(localized: "Служба")) { job in
                    HStack(spacing: 6) {
                        ProcessIcon(path: job.target ?? "", size: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(job.label).lineLimit(1)
                                .foregroundStyle(job.enabled ? .primary : .secondary)
                            Text(job.displayCommand)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .help(job.plistPath)
                }
                .width(min: 220, ideal: 320)

                TableColumn(String(localized: "Запуск")) { job in
                    Text(job.trigger).foregroundStyle(job.enabled ? .primary : .secondary)
                }
                .width(min: 120, ideal: 170)

                TableColumn(String(localized: "Состояние")) { job in
                    JobStatus(job: job, pid: runningPID(job))
                }
                .width(min: 110, ideal: 130)

                TableColumn(String(localized: "Разработчик")) { job in
                    VendorLabel(job: job)
                }
                .width(min: 120, ideal: 170)

                TableColumn(String(localized: "Тип")) { job in
                    Text(job.scope.short).foregroundStyle(.secondary)
                        .help(job.scope.title)
                }
                .width(min: 90, ideal: 110)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let job = store.jobs.first(where: { $0.id == ids.first }) {
                    jobMenu(job, pid: runningPID(job))
                }
            } primaryAction: { ids in
                if let job = store.jobs.first(where: { $0.id == ids.first }), let pid = runningPID(job) {
                    state.section = .processes
                    state.showChain(pid)
                }
            }
            .overlay {
                if store.loadedOnce && jobs.isEmpty {
                    ContentUnavailableView("Ничего не найдено", systemImage: "power",
                                           description: Text("Нет служб, подходящих под фильтр."))
                }
            }

            Divider()
            HStack {
                Text("Служб: \(jobs.count) · включено: \(jobs.filter(\.enabled).count)")
                Spacer()
                Button("Объекты входа в Системных настройках…") {
                    NSWorkspace.shared.open(SystemSettingsLinks.loginItems)
                }
                .help("Там же — фоновые объекты, которые приложения регистрируют сами («Разрешить в фоне»)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .confirmationDialog("Удалить «\(pendingTrash?.label ?? "")»?",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                            presenting: pendingTrash) { job in
            Button("Переместить в Корзину", role: .destructive) {
                Task { await store.moveToTrash(job) }
            }
        } message: { _ in
            Text("Служба будет остановлена, а её plist-файл перемещён в Корзину. Восстановить можно, вернув файл из Корзины. Программа при следующем запуске может создать его заново — тогда лучше просто выключить службу.")
        }
    }

    @ViewBuilder
    private func jobMenu(_ job: LaunchJob, pid: pid_t?) -> some View {
        let store = state.startup
        Button(job.enabled ? String(localized: "Выключить автозапуск") : String(localized: "Включить автозапуск")) {
            Task { await store.setEnabled(job, !job.enabled) }
        }
        if let pid {
            Button("Показать процесс (PID \(String(pid)))") {
                state.section = .processes
                state.showChain(pid)
            }
        }
        Divider()
        Button("Показать plist в Finder") { AppState.revealInFinder(job.plistPath) }
        if let target = job.target, job.programExists {
            Button("Показать программу в Finder") { AppState.revealInFinder(target) }
        }
        Button("Скопировать метку") { AppState.copy(job.label) }
        if job.scope == .userAgent {
            Divider()
            Button("Удалить…") { pendingTrash = job }
        }
    }
}

struct JobToggle: View {
    let job: LaunchJob
    /// Явно, а не через окружение — ячейки таблицы рендерятся в отдельных хостах.
    let store: StartupStore

    var body: some View {
        if store.busy.contains(job.id) {
            ProgressView().controlSize(.small)
        } else {
            Toggle("", isOn: Binding(
                get: { job.enabled },
                set: { newValue in Task { await store.setEnabled(job, newValue) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(job.enabled ? String(localized: "Выключить автозапуск") : String(localized: "Включить автозапуск")
                  + (job.scope.needsAdmin ? String(localized: " (нужен пароль администратора)") : ""))
        }
    }
}

struct JobStatus: View {
    let job: LaunchJob
    let pid: pid_t?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(pid != nil ? Color.green : (job.enabled ? Color.secondary.opacity(0.4) : Color.red.opacity(0.7)))
                .frame(width: 7, height: 7)
            if let pid {
                Text("Работает · \(String(pid))").monospacedDigit()
            } else {
                Text(job.enabled ? String(localized: "Не запущена") : String(localized: "Выключена")).foregroundStyle(.secondary)
            }
        }
    }
}

struct VendorLabel: View {
    let job: LaunchJob

    var body: some View {
        HStack(spacing: 4) {
            if job.target != nil && !job.programExists {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if job.isScript {
                Image(systemName: "scroll").foregroundStyle(.secondary)
            } else if let s = job.signing {
                if s.isApple {
                    Image(systemName: "apple.logo")
                } else if s.unsigned || s.isAdhoc {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
            Text(job.vendor).lineLimit(1)
        }
        .help(job.target != nil && !job.programExists
              ? String(localized: "Программа удалена, а служба осталась — её можно выключить или удалить")
              : (job.signing?.teamID.map { "Team ID: \($0)" } ?? ""))
    }
}

// MARK: - Объекты входа

struct LoginItemsView: View {
    @Environment(AppState.self) private var state
    @State private var selection: String?
    @State private var pendingRemoval: LoginItem?

    var body: some View {
        let store = state.startup
        switch store.loginAccess {
        case .granted:
            itemsTable
        case .unknown, .needsConsent:
            ContentUnavailableView {
                Label("Нужен доступ к System Events", systemImage: "person.badge.key")
            } description: {
                Text("Список «Открывать при входе» macOS отдаёт только через System Events. Система один раз спросит разрешение для PerfMom.")
            } actions: {
                Button("Разрешить и показать") { Task { await store.requestLoginAccess() } }
                    .buttonStyle(.borderedProminent)
            }
        case .denied:
            ContentUnavailableView {
                Label("Доступ запрещён", systemImage: "hand.raised")
            } description: {
                Text("Разрешите PerfMom управлять System Events: Системные настройки → Конфиденциальность и безопасность → Автоматизация.")
            } actions: {
                Button("Открыть настройки автоматизации") { NSWorkspace.shared.open(SystemSettingsLinks.automation) }
                Button("Проверить снова") { Task { await store.refreshLoginItems() } }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Не удалось получить список", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Повторить") { Task { await store.requestLoginAccess() } }
            }
        }
    }

    private var itemsTable: some View {
        let store = state.startup
        let q = state.search.trimmingCharacters(in: .whitespaces)
        let items = store.loginItems.filter {
            q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q)
        }
        let runningPaths = Set(state.monitor.processes.compactMap { PathTools.outermostApp($0.path) })

        return VStack(spacing: 0) {
            Table(items, selection: $selection) {
                TableColumn(String(localized: "Приложение")) { item in
                    HStack(spacing: 6) {
                        ProcessIcon(path: item.path, size: 18)
                        Text(item.name).lineLimit(1)
                    }
                }
                .width(min: 180, ideal: 240)

                TableColumn(String(localized: "Состояние")) { item in
                    let running = runningPaths.contains(item.path)
                    HStack(spacing: 5) {
                        Circle().fill(running ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        Text(running ? String(localized: "Запущено") : String(localized: "Не запущено")).foregroundStyle(running ? .primary : .secondary)
                    }
                }
                .width(min: 100, ideal: 120)

                TableColumn(String(localized: "Скрывать окна")) { item in
                    Toggle("", isOn: Binding(get: { item.hidden }, set: { store.setHidden(item, $0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help("Запускать приложение скрытым")
                }
                .width(90)

                TableColumn(String(localized: "Расположение")) { item in
                    Text(item.path.isEmpty ? "—" : item.path)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .help(item.path)
                }
                .width(min: 160, ideal: 360)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let item = store.loginItems.first(where: { $0.id == ids.first }) {
                    Button("Показать в Finder") { AppState.revealInFinder(item.path) }.disabled(item.path.isEmpty)
                    Button(item.hidden ? String(localized: "Не скрывать окна") : String(localized: "Скрывать окна")) { store.setHidden(item, !item.hidden) }
                    Divider()
                    Button("Убрать из автозагрузки…") { pendingRemoval = item }
                }
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Нет объектов входа", systemImage: "power",
                                           description: Text("Нажмите «+», чтобы добавить приложение."))
                }
            }

            Divider()
            // Кнопки «+ / −» внизу списка — как в Системных настройках.
            HStack(spacing: 0) {
                Button { addItem() } label: {
                    Image(systemName: "plus").frame(width: 24, height: 20)
                }
                .help("Добавить приложение в автозагрузку")
                Divider().frame(height: 16)
                Button {
                    pendingRemoval = store.loginItems.first { $0.id == selection }
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 20)
                }
                .disabled(selection == nil)
                .help("Убрать выбранное приложение из автозагрузки")
                Spacer()
                Button {
                    store.loadLoginItems()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить")
                .padding(.trailing, 8)
            }
            .buttonStyle(.borderless)
            .padding(6)
            .background(.bar)
        }
        .confirmationDialog("Убрать «\(pendingRemoval?.name ?? "")» из автозагрузки?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { item in
            Button("Убрать", role: .destructive) {
                store.removeLoginItem(item)
                selection = nil
            }
        } message: { _ in
            Text("Приложение не будет открываться при входе в систему. Само приложение не удаляется.")
        }
    }

    private func addItem() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Добавить в автозагрузку")
        panel.prompt = String(localized: "Добавить")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { state.startup.addLoginItem(url) }
    }
}

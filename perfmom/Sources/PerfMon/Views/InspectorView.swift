import SwiftUI

struct InspectorView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let pid = state.selectedPID, let rec = state.monitor.byPID[pid] {
                ProcessInspector(record: rec)
            } else if let pid = state.selectedPID {
                ContentUnavailableView {
                    Label("Процесс завершён", systemImage: "xmark.circle")
                } description: {
                    Text("PID \(String(pid)) больше не выполняется.")
                }
            } else {
                ContentUnavailableView {
                    Label("Процесс не выбран", systemImage: "cursorarrow.click.2")
                } description: {
                    Text("Выберите процесс, чтобы увидеть цепочку запуска, открытые файлы и загруженные модули.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProcessInspector: View {
    let record: ProcessRecord
    @Environment(AppState.self) private var state
    @State private var details: ProcessDetails?
    @State private var adminBusy = false

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            InspectorHeader(record: record)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 12)
            Picker("Раздел", selection: $state.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: record.pid) { await reload() }
    }

    @ViewBuilder private var tabContent: some View {
        switch state.inspectorTab {
        case .summary: SummaryTab(record: record, details: details)
        case .chain: ChainTab(record: record, details: details)
        case .files:
            FilesTab(record: record, details: details, adminBusy: adminBusy,
                     onAdmin: loadAsAdmin, onReload: { Task { await reload() } })
        case .modules:
            ModulesTab(record: record, details: details, adminBusy: adminBusy,
                       onAdmin: loadAsAdmin, onReload: { Task { await reload() } })
        case .launch: LaunchTab(details: details)
        }
    }

    private func reload() async {
        let pid = record.pid, path = record.path
        let loaded = await Task.detached(priority: .userInitiated) {
            DetailsLoader.load(pid: pid, path: path)
        }.value
        guard pid == record.pid else { return }
        details = loaded
    }

    private func loadAsAdmin() {
        let pid = record.pid, path = record.path
        adminBusy = true
        Task {
            defer { adminBusy = false }
            do {
                let res = try await DetailsLoader.loadAsAdmin(pid: pid, executable: path)
                guard pid == record.pid else { return }
                var d = details ?? ProcessDetails()
                d.files = res.files
                d.filesAvailable = true
                d.modules = res.modules
                d.modulesAvailable = true
                if let cwd = res.cwd { d.cwd = cwd }
                d.viaAdmin = true
                details = d
            } catch AdminRunner.Failure.cancelled {
            } catch {
                state.alert = AlertInfo(title: "Не удалось получить данные", message: error.localizedDescription)
            }
        }
    }
}

// MARK: - Шапка с кнопками управления

struct InspectorHeader: View {
    let record: ProcessRecord
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProcessIcon(path: record.path, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("PID \(String(record.pid)) · \(record.user)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if record.restricted {
                // Без fixedSize: при расчёте идеального размера инспектора текст мерился бы на нулевой
                // ширине и раздувал высоту всего окна.
                Label("Процесс пользователя «\(record.user)»: файлы и модули — с паролем администратора.",
                      systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                Button {
                    state.request(.terminate, pid: record.pid)
                } label: {
                    Label("Завершить", systemImage: "xmark.circle")
                }
                .help("Корректно завершить (SIGTERM / «Завершить» для приложений)")

                Button(role: .destructive) {
                    state.request(.forceQuit, pid: record.pid)
                } label: {
                    Label("Принудительно", systemImage: "bolt.circle")
                }
                .help("Немедленно остановить (SIGKILL)")

                if record.state == .stopped {
                    Button { state.request(.resume, pid: record.pid) } label: {
                        Image(systemName: "play.circle")
                    }
                    .help("Продолжить выполнение (SIGCONT)")
                } else {
                    Button { state.request(.suspend, pid: record.pid) } label: {
                        Image(systemName: "pause.circle")
                    }
                    .help("Приостановить (SIGSTOP)")
                }

                Menu {
                    ProcessMenuItems(pid: record.pid, state: state)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Другие действия")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Сводка

struct SummaryTab: View {
    let record: ProcessRecord
    let details: ProcessDetails?
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.monitor
        let cpuHistory = m.processCPUHistory[record.pid] ?? []
        let memHistory = m.processMemoryHistory[record.pid] ?? []

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Оценку безопасности показываем первой, только если есть что сказать.
                if record.security.level > .none || state.isTrusted(record) {
                    SecuritySection(record: record)
                }

                InspectorSection("Ресурсы") {
                    HStack {
                        MetricTile(title: "ЦП", value: "\(Fmt.percent(record.cpu)) %")
                        MetricTile(title: "Память", value: Fmt.bytes(record.memory))
                        MetricTile(title: "Потоки", value: record.threads.map(String.init) ?? "—")
                    }
                    Text("ЦП, %").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    HistoryChart(series: [ChartSeries(name: "ЦП", color: .blue, values: cpuHistory)],
                                 capacity: 60, maxValue: max(100, (cpuHistory.max() ?? 0) * 1.1))
                        .frame(height: 56)
                    Text("Память").font(.caption).foregroundStyle(.secondary)
                    HistoryChart(series: [ChartSeries(name: "Память", color: .green, values: memHistory)],
                                 capacity: 60)
                        .frame(height: 44)
                }

                NetworkSection(record: record)

                InspectorSection("Диск") {
                    KeyValueRow(key: "Чтение", value: Fmt.rate(record.diskRead))
                    KeyValueRow(key: "Запись", value: Fmt.rate(record.diskWrite))
                    KeyValueRow(key: "Всего прочитано", value: record.diskReadTotal.map(Fmt.bytes) ?? "—")
                    KeyValueRow(key: "Всего записано", value: record.diskWriteTotal.map(Fmt.bytes) ?? "—")
                }

                InspectorSection("Процесс") {
                    KeyValueRow(key: "Состояние", value: record.state.title)
                    if let start = record.startTime {
                        KeyValueRow(key: "Запущен", value: Fmt.dateTime(start))
                        KeyValueRow(key: "Работает", value: Fmt.duration(Date().timeIntervalSince(start)))
                    }
                    KeyValueRow(key: "Время ЦП", value: Fmt.cpuTime(record.cpuTime))
                    KeyValueRow(key: "Пользователь", value: "\(record.user) (uid \(record.uid))")
                    linkRow("Родитель", pid: record.ppid)
                    if let resp = details?.responsiblePID, resp != record.pid {
                        linkRow("Ответственный", pid: resp)
                    }
                }

                InspectorSection("Исполняемый файл") {
                    if record.path.isEmpty {
                        Text("Путь недоступен").foregroundStyle(.secondary)
                    } else {
                        Text(record.path)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let size = details?.executableSize {
                            KeyValueRow(key: "Размер", value: Fmt.bytes(size))
                        }
                        if let mod = details?.executableModified {
                            KeyValueRow(key: "Изменён", value: Fmt.dateTime(mod))
                        }
                        HStack {
                            Button("Показать в Finder") { AppState.revealInFinder(record.path) }
                            Button("Скопировать путь") { AppState.copy(record.path) }
                        }
                        .controlSize(.small)
                    }
                }

                if let sig = details?.signing {
                    SigningSection(signing: sig)
                }

                if record.security.level == .none && !state.isTrusted(record) {
                    SecuritySection(record: record)
                }

                if let b = details?.bundle {
                    InspectorSection("Пакет приложения") {
                        if let name = b.name { KeyValueRow(key: "Название", value: name) }
                        if let id = b.identifier { KeyValueRow(key: "Bundle ID", value: id, monospaced: true) }
                        if let v = b.version, !v.isEmpty { KeyValueRow(key: "Версия", value: v) }
                        KeyValueRow(key: "Расположение", value: b.path)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private func linkRow(_ title: String, pid: pid_t) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
            if let r = state.monitor.byPID[pid] {
                ProcessLink(record: r)
            } else {
                Text(verbatim: "PID \(pid)").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

struct NetworkSection: View {
    let record: ProcessRecord
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.monitor
        let inHist = m.processNetInHistory[record.pid] ?? []
        let outHist = m.processNetOutHistory[record.pid] ?? []
        let sockets = record.netInTotal == nil ? nil : (record.netInTotal ?? 0) + (record.netOutTotal ?? 0)

        InspectorSection("Сеть") {
            if record.netIn == nil {
                Text("Данные о сетевой активности недоступны (nettop не запущен).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    MetricTile(title: "↓ Получено", value: Fmt.rate(record.netIn))
                    MetricTile(title: "↑ Отправлено", value: Fmt.rate(record.netOut))
                }
                if !inHist.isEmpty, inHist.contains(where: { $0 > 0 }) || outHist.contains(where: { $0 > 0 }) {
                    HistoryChart(series: [
                        ChartSeries(name: "Получено", color: .blue, values: inHist),
                        ChartSeries(name: "Отправлено", color: .orange, values: outHist),
                    ], capacity: 60)
                    .frame(height: 56)
                } else {
                    Text(sockets == 0 ? "Процесс не обменивался данными по сети." : "Сейчас трафика нет.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                KeyValueRow(key: "По открытым соединениям",
                            value: "↓ \(Fmt.bytes(record.netInTotal ?? 0))   ↑ \(Fmt.bytes(record.netOutTotal ?? 0))")
                Button("Показать соединения") { state.inspectorTab = .files }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
    }
}

struct SigningSection: View {
    let signing: SigningInfo

    var body: some View {
        InspectorSection("Подпись кода") {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(signing.summary).fontWeight(.medium)
            }
            .font(.callout)
            if let id = signing.identifier { KeyValueRow(key: "Идентификатор", value: id, monospaced: true) }
            if let team = signing.teamID { KeyValueRow(key: "Team ID", value: team, monospaced: true) }
            if let auth = signing.authority, !signing.isApple { KeyValueRow(key: "Сертификат", value: auth) }
            if !signing.unsigned {
                KeyValueRow(key: "Hardened Runtime", value: signing.hardenedRuntime ? "Включён" : "Выключен")
            }
        }
    }

    private var icon: String {
        if signing.unsigned { return "exclamationmark.shield.fill" }
        if signing.isApple { return "apple.logo" }
        if signing.isAdhoc { return "exclamationmark.shield" }
        return "checkmark.shield.fill"
    }

    private var color: Color {
        if signing.unsigned { return .red }
        if signing.isAdhoc { return .orange }
        return signing.isApple ? .primary : .green
    }
}

// MARK: - Цепочка запуска

struct ChainTab: View {
    let record: ProcessRecord
    let details: ProcessDetails?
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.monitor
        let chain = m.ancestry(of: record.pid)
        let kids = (m.children[record.pid] ?? []).compactMap { m.byPID[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("От ядра до исполняемого файла")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)

                    ForEach(Array(chain.enumerated()), id: \.element.pid) { item in
                        ChainNode(record: item.element,
                                  isFirst: item.offset == 0,
                                  isLast: false,
                                  isCurrent: item.element.pid == record.pid)
                    }
                    ChainFileNode(path: record.path, signing: details?.signing)
                }

                if let resp = details?.responsiblePID, resp != record.pid, let r = m.byPID[resp] {
                    InspectorSection("Ответственное приложение") {
                        Text("macOS считает этот процесс запущенным от имени:")
                            .font(.caption).foregroundStyle(.secondary)
                        ProcessLink(record: r)
                    }
                }

                InspectorSection("Дочерние процессы (\(kids.count))") {
                    if kids.isEmpty {
                        Text("Нет дочерних процессов").foregroundStyle(.secondary).font(.callout)
                    } else {
                        ForEach(kids) { k in ProcessLink(record: k) }
                        if (m.subtree[record.pid]?.descendants ?? 0) > kids.count {
                            Button("Показать всех потомков в дереве") { state.revealInTree(record.pid) }
                                .controlSize(.small)
                                .padding(.top, 4)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct ChainLine: View {
    let hideTop: Bool
    let hideBottom: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(hideTop ? Color.clear : Color.secondary.opacity(0.35))
            Rectangle().fill(hideBottom ? Color.clear : Color.secondary.opacity(0.35))
        }
        .frame(width: 2)
        .padding(.leading, 9)
    }
}

struct ChainNode: View {
    let record: ProcessRecord
    let isFirst: Bool
    let isLast: Bool
    let isCurrent: Bool
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            state.select(record.pid, tab: .chain)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.6))
                    .frame(width: isCurrent ? 12 : 8, height: isCurrent ? 12 : 8)
                    .frame(width: 20)
                ProcessIcon(path: record.path, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(record.name)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .lineLimit(1)
                        Text(verbatim: "\(record.pid)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(record.path.isEmpty ? record.user : record.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text("\(Fmt.percent(record.cpu)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
            .background(alignment: .leading) { ChainLine(hideTop: isFirst, hideBottom: isLast) }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(record.path)
        .contextMenu { ProcessMenuItems(pid: record.pid, state: state) }
    }
}

struct ChainFileNode: View {
    let path: String
    let signing: SigningInfo?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Image(nsImage: IconCache.shared.icon(for: path))
                .resizable().frame(width: 24, height: 24)
                .opacity(path.isEmpty ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text("Исполняемый файл").font(.caption).foregroundStyle(.secondary)
                Text(path.isEmpty ? "Недоступен" : path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let signing {
                    Text("Подпись: \(signing.summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if !path.isEmpty {
                Button {
                    AppState.revealInFinder(path)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Показать в Finder")
            }
        }
        .padding(.vertical, 6)
        .background(alignment: .leading) {
            VStack(spacing: 0) {
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 14)
                Spacer()
            }
            .frame(width: 2)
            .padding(.leading, 9)
        }
    }
}

// MARK: - Открытые файлы

struct FilesTab: View {
    let record: ProcessRecord
    let details: ProcessDetails?
    let adminBusy: Bool
    let onAdmin: () -> Void
    let onReload: () -> Void
    @State private var query = ""

    var body: some View {
        if let details {
            if !details.filesAvailable {
                RestrictedView(what: "открытые файлы и сетевые соединения", busy: adminBusy, onAdmin: onAdmin)
            } else {
                let items = details.files.filter {
                    query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                        || $0.detail.localizedCaseInsensitiveContains(query)
                }
                VStack(spacing: 0) {
                    FilterBar(query: $query, count: items.count, total: details.files.count,
                              viaAdmin: details.viaAdmin, onReload: onReload)
                    List {
                        ForEach([0, 1, 2], id: \.self) { group in
                            let groupItems = items.filter { $0.kind.group == group }
                            if !groupItems.isEmpty {
                                Section("\(groupTitle(group)) (\(groupItems.count))") {
                                    ForEach(groupItems) { FileRow(file: $0) }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func groupTitle(_ g: Int) -> String {
        switch g {
        case 0: "Файлы и папки"
        case 1: "Сеть и сокеты"
        default: "Каналы и прочее"
        }
    }
}

struct FileRow: View {
    let file: OpenFile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.kind.symbol)
                .foregroundStyle(file.kind == .socket ? Color.blue : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.title).lineLimit(1).truncationMode(.middle)
                if !file.detail.isEmpty && file.detail != file.title {
                    Text(file.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Text(file.fd)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .help("Файловый дескриптор")
        }
        .help(file.path ?? file.title)
        .contextMenu {
            if let p = file.path {
                Button("Показать в Finder") { AppState.revealInFinder(p) }
                Button("Скопировать путь") { AppState.copy(p) }
            } else {
                Button("Скопировать") { AppState.copy(file.title) }
            }
        }
    }
}

// MARK: - Загруженные модули

struct ModulesTab: View {
    let record: ProcessRecord
    let details: ProcessDetails?
    let adminBusy: Bool
    let onAdmin: () -> Void
    let onReload: () -> Void
    @State private var query = ""

    var body: some View {
        if let details {
            if !details.modulesAvailable {
                RestrictedView(what: "загруженные библиотеки и отображённые файлы", busy: adminBusy, onAdmin: onAdmin)
            } else {
                let items = details.modules.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
                VStack(spacing: 0) {
                    FilterBar(query: $query, count: items.count, total: details.modules.count,
                              viaAdmin: details.viaAdmin, onReload: onReload)
                    List {
                        ForEach(ModuleKind.allCases, id: \.self) { kind in
                            let group = items.filter { $0.kind == kind }
                            if !group.isEmpty {
                                Section("\(kind.title) (\(group.count))") {
                                    ForEach(group) { ModuleRow(module: $0) }
                                }
                            }
                        }
                        Section {
                            Text("Системные библиотеки macOS загружаются одним блоком из общего кэша dyld, поэтому по отдельности здесь видны только сторонние библиотеки, фреймворки приложения и отображённые файлы.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

struct ModuleRow: View {
    let module: ModuleEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: module.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(module.title).lineLimit(1)
                Text(module.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(module.path)
        .contextMenu {
            Button("Показать в Finder") { AppState.revealInFinder(module.path) }
            Button("Скопировать путь") { AppState.copy(module.path) }
        }
    }
}

struct FilterBar: View {
    @Binding var query: String
    let count: Int
    let total: Int
    let viaAdmin: Bool
    let onReload: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Фильтр", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))

            Text(count == total ? "\(total)" : "\(count) из \(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if viaAdmin {
                Image(systemName: "lock.open.fill").foregroundStyle(.orange).font(.caption)
                    .help("Получено с правами администратора")
            }
            Button(action: onReload) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Обновить")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct RestrictedView: View {
    let what: String
    let busy: Bool
    let onAdmin: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Нужны права администратора", systemImage: "lock.shield")
        } description: {
            Text("Процесс принадлежит другому пользователю. macOS не разрешает смотреть его \(what) без повышения прав.")
        } actions: {
            Button {
                onAdmin()
            } label: {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Показать с паролем администратора")
                }
            }
            .disabled(busy)
        }
    }
}

// MARK: - Параметры запуска

struct LaunchTab: View {
    let details: ProcessDetails?
    @State private var showEnv = false

    var body: some View {
        if let details {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InspectorSection(details.argumentsFromPS ? "Командная строка" : "Аргументы (\(details.arguments.count))") {
                        if details.arguments.isEmpty {
                            Text("Недоступны").foregroundStyle(.secondary).font(.callout)
                        } else {
                            ForEach(Array(details.arguments.enumerated()), id: \.offset) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if !details.argumentsFromPS {
                                        Text("\(item.offset)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 20, alignment: .trailing)
                                    }
                                    Text(item.element)
                                        .font(.callout.monospaced())
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Button("Скопировать командную строку") {
                                AppState.copy(details.arguments.map(shellQuote).joined(separator: " "))
                            }
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    }

                    InspectorSection("Рабочая папка") {
                        if let cwd = details.cwd {
                            HStack {
                                Text(cwd).font(.callout.monospaced()).textSelection(.enabled)
                                Spacer()
                                Button { AppState.revealInFinder(cwd) } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.borderless)
                                    .help("Показать в Finder")
                            }
                        } else {
                            Text("Недоступна").foregroundStyle(.secondary).font(.callout)
                        }
                    }

                    if !details.environment.isEmpty {
                        InspectorSection("Окружение") {
                            DisclosureGroup("Переменные (\(details.environment.count))", isExpanded: $showEnv) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(details.environment, id: \.self) { line in
                                        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text(parts.first ?? line).font(.caption.monospaced().weight(.semibold))
                                            Text(parts.count > 1 ? parts[1] : "")
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                                .lineLimit(3)
                                        }
                                    }
                                }
                                .padding(.top, 6)
                            }
                            .font(.callout)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = s.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:,@+%".contains($0) }
        return safe ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

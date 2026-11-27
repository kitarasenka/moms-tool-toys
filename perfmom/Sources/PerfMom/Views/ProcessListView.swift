import SwiftUI

/// Строка таблицы с позиционной идентичностью. Если идентифицировать строки по PID, то при каждой
/// пересортировке NSTableView удаляет и заново создаёт сотни строк (~10% ЦП); со слотами меняется
/// только содержимое видимых строк, а выделение «следует» за процессом через `pidSelection`.
struct Slot: Identifiable {
    let id: Int
    let record: ProcessRecord
}

extension Array where Element == Slot {
    init(records: [ProcessRecord]) {
        self = records.enumerated().map { Slot(id: $0.offset, record: $0.element) }
    }

    @MainActor
    func pidSelection(_ state: AppState) -> Binding<Int?> {
        Binding(
            get: { state.selectedPID.flatMap { pid in firstIndex { $0.record.pid == pid } } },
            set: { idx in
                guard let idx, indices.contains(idx) else { return }
                state.selectedPID = self[idx].record.pid
            }
        )
    }

    func pid(_ slot: Int?) -> pid_t? {
        guard let slot, indices.contains(slot) else { return nil }
        return self[slot].record.pid
    }
}

struct ProcessListView: View {
    @Environment(AppState.self) private var state
    @State private var sortOrder = [KeyPathComparator(\Slot.record.cpu, order: .reverse)]
    @SceneStorage("ProcessTableColumns") private var columnCustomization: TableColumnCustomization<Slot>

    var body: some View {
        @Bindable var state = state
        let sorted = state.filteredProcesses.map { Slot(id: 0, record: $0) }.sorted(using: sortOrder)
        let rows = [Slot](records: sorted.map(\.record))

        // Столбцы можно скрывать/показывать правым кликом по заголовку; набор запоминается.
        Table(rows, selection: rows.pidSelection(state), sortOrder: $sortOrder,
              columnCustomization: $columnCustomization) {
            primaryColumns
            trafficColumns
            infoColumns
        }
        .leadingTableScrollPosition()
        .contextMenu(forSelectionType: Int.self) { slots in
            if let pid = rows.pid(slots.first) {
                ProcessMenuItems(pid: pid, state: state)
            }
        } primaryAction: { slots in
            if let pid = rows.pid(slots.first) { state.showChain(pid) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(shown: rows.count)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Фильтр", selection: $state.filter) {
                    ForEach(ProcessFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Какие процессы показывать")
            }
        }
        .navigationTitle("Процессы")
    }
    @TableColumnBuilder<Slot, KeyPathComparator<Slot>>
    private var primaryColumns: some TableColumnContent<Slot, KeyPathComparator<Slot>> {
        TableColumn(String(localized: "Процесс"), value: \.record.name) { s in
            ProcessNameCell(record: s.record, risk: state.risk(s.record))
        }
        .width(min: 180, ideal: 240)
        .customizationID("name")
        .disabledCustomizationBehavior(.visibility)

        TableColumn(String(localized: "% ЦП"), value: \.record.cpu) { s in
            Text(Fmt.percent(s.record.cpu))
                .monospacedDigit()
                .foregroundStyle(s.record.cpu >= 80 ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .width(min: 54, ideal: 64)
        .customizationID("cpu")

        TableColumn(String(localized: "Время ЦП"), value: \.record.cpuTime) { s in
            Text(Fmt.cpuTime(s.record.cpuTime)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .width(min: 70, ideal: 84)
        .customizationID("cpuTime")
        .defaultVisibility(.hidden)

        TableColumn(String(localized: "Память"), value: \.record.memory) { s in
            Text(Fmt.bytes(s.record.memory)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .width(min: 70, ideal: 84)
        .customizationID("memory")

        TableColumn(String(localized: "Потоки"), value: \.record.threadsSort) { s in
            Text(s.record.threads.map(String.init) ?? "—").monospacedDigit()
                .foregroundStyle(s.record.threads == nil ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .width(min: 50, ideal: 56)
        .customizationID("threads")
    }


    @TableColumnBuilder<Slot, KeyPathComparator<Slot>>
    private var trafficColumns: some TableColumnContent<Slot, KeyPathComparator<Slot>> {
        TableColumn(String(localized: "Сеть ↓"), value: \.record.netInSort) { s in
            RateText(value: s.record.netIn)
        }
        .width(min: 70, ideal: 84)
        .customizationID("netIn")

        TableColumn(String(localized: "Сеть ↑"), value: \.record.netOutSort) { s in
            RateText(value: s.record.netOut)
        }
        .width(min: 70, ideal: 84)
        .customizationID("netOut")

        TableColumn(String(localized: "Диск: чтение"), value: \.record.diskReadSort) { s in
            RateText(value: s.record.diskRead)
        }
        .width(min: 70, ideal: 84)
        .customizationID("diskRead")

        TableColumn(String(localized: "Диск: запись"), value: \.record.diskWriteSort) { s in
            RateText(value: s.record.diskWrite)
        }
        .width(min: 70, ideal: 84)
        .customizationID("diskWrite")
    }


    @TableColumnBuilder<Slot, KeyPathComparator<Slot>>
    private var infoColumns: some TableColumnContent<Slot, KeyPathComparator<Slot>> {
        TableColumn("PID", value: \.record.pid) { s in
            Text(verbatim: "\(s.record.pid)").monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .width(min: 50, ideal: 60)
        .customizationID("pid")

        TableColumn(String(localized: "Пользователь"), value: \.record.user) { s in
            Text(s.record.user).foregroundStyle(s.record.isSystem ? .secondary : .primary)
        }
        .width(min: 70, ideal: 100)
        .customizationID("user")

        TableColumn(String(localized: "Путь"), value: \.record.path) { s in
            Text(s.record.path.isEmpty ? "—" : s.record.path)
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
                .help(s.record.path)
        }
        .width(min: 120, ideal: 320)
        .customizationID("path")
    }
}

struct RateText: View {
    let value: Double?

    var body: some View {
        Text(Fmt.rate(value))
            .monospacedDigit()
            .foregroundStyle(value == nil ? .tertiary : ((value ?? 0) > 0 ? .primary : .secondary))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ProcessNameCell: View {
    let record: ProcessRecord
    var risk: RiskLevel = .none

    var body: some View {
        HStack(spacing: 6) {
            ProcessIcon(path: record.path, size: 16)
            Text(record.name).lineLimit(1)
            StateBadges(record: record, risk: risk)
        }
        .help(record.path.isEmpty ? record.name : record.path)
    }
}

struct StateBadges: View {
    let record: ProcessRecord
    var risk: RiskLevel = .none

    var body: some View {
        if risk >= .warning {
            Image(systemName: risk.symbol)
                .foregroundStyle(risk.color)
                .help("\(risk.title): " + record.security.findings.map(\.title).joined(separator: ", "))
        }
        if record.state == .stopped {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
                .help("Процесс приостановлен")
        }
        if record.state == .zombie {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help("Зомби: процесс завершился, но родитель не забрал код выхода")
        }
        if record.restricted {
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Процесс другого пользователя — часть данных доступна только администратору")
        }
    }
}

struct StatusBar: View {
    let shown: Int
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.monitor
        let s = m.system
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 18) {
                Text("Показано \(shown) из \(m.processes.count)")
                Text("Потоков: \(Fmt.number(m.totalThreads))")
                Spacer()
                Label("\(Fmt.percent(s.cpuTotal)) %", systemImage: "cpu")
                Label("\(Fmt.bytes(s.memUsed)) из \(Fmt.bytes(s.memTotal))", systemImage: "memorychip")
                Label("↓ \(Fmt.rate(s.netIn))  ↑ \(Fmt.rate(s.netOut))", systemImage: "network")
                if m.paused {
                    Label("Пауза", systemImage: "pause.fill").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

// MARK: - Контекстное меню процесса

/// Пункты меню получают состояние явно: SwiftUI рисует контекстные меню в отдельном хосте,
/// куда `@Environment(AppState.self)` иногда не доходит — это приводило к падению.
struct ProcessMenuItems: View {
    let pid: pid_t
    let state: AppState

    var body: some View {
        let rec = state.monitor.byPID[pid]
        let path = rec?.path ?? ""
        let childCount = state.monitor.subtree[pid]?.descendants ?? 0

        Button("Показать цепочку запуска") { state.showChain(pid) }
        Button("Показать в дереве процессов") { state.revealInTree(pid) }
        Button("Показать в Finder") { AppState.revealInFinder(path) }
            .disabled(path.isEmpty)

        Divider()

        Button("Скопировать путь") { AppState.copy(path) }
            .disabled(path.isEmpty)
        Button("Скопировать PID") { AppState.copy(String(pid)) }

        Divider()

        if rec?.state == .stopped {
            Button("Продолжить выполнение") { state.request(.resume, pid: pid) }
        } else {
            Button("Приостановить") { state.request(.suspend, pid: pid) }
        }
        Button("Завершить…") { state.request(.terminate, pid: pid) }
        Button("Завершить принудительно…") { state.request(.forceQuit, pid: pid) }
        if childCount > 0 {
            Button("Завершить вместе с дочерними (\(childCount))…") {
                state.request(.terminate, pid: pid, includeChildren: true)
            }
        }
    }
}

import SwiftUI

struct ProcessTreeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let rows = state.treeRows()
        let selection = Binding<Int?>(
            get: { state.selectedPID.flatMap { pid in rows.firstIndex { $0.record.pid == pid } } },
            set: { idx in
                if let idx, rows.indices.contains(idx) { state.selectedPID = rows[idx].record.pid }
            }
        )
        let pidAt: (Int?) -> pid_t? = { idx in
            guard let idx, rows.indices.contains(idx) else { return nil }
            return rows[idx].record.pid
        }

        Table(rows, selection: selection) {
            TableColumn("Процесс") { row in
                TreeNameCell(row: row, state: state)
            }
            .width(min: 260, ideal: 340)

            TableColumn("% ЦП") { row in
                Text(Fmt.percent(row.record.cpu)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 54, ideal: 60)

            TableColumn("Σ ЦП") { row in
                Text(row.hasChildren ? Fmt.percent(row.totals.cpu) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("Сумма по процессу и всем его потомкам")
            }
            .width(min: 54, ideal: 64)

            TableColumn("Память") { row in
                Text(Fmt.bytes(row.record.memory)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 84)

            TableColumn("Σ Память") { row in
                Text(row.hasChildren ? Fmt.bytes(row.totals.memory) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Сеть") { row in
                Text(row.record.netIn == nil ? "—" : Fmt.rate(row.record.netTotalRate))
                    .monospacedDigit()
                    .foregroundStyle(row.record.netTotalRate > 0 ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("Получено + отправлено в секунду")
            }
            .width(min: 70, ideal: 84)

            TableColumn("Σ Сеть") { row in
                Text(row.hasChildren && row.record.netIn != nil ? Fmt.rate(row.totals.net) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("Сетевой трафик процесса и всех его потомков")
            }
            .width(min: 70, ideal: 90)

            TableColumn("PID") { row in
                Text(verbatim: "\(row.record.pid)").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Пользователь") { row in
                Text(row.record.user).foregroundStyle(row.record.isSystem ? .secondary : .primary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Путь") { row in
                Text(row.record.path.isEmpty ? "—" : row.record.path)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .help(row.record.path)
            }
            .width(min: 120, ideal: 300)
        }
        .contextMenu(forSelectionType: Int.self) { slots in
            if let pid = pidAt(slots.first) { ProcessMenuItems(pid: pid, state: state) }
        } primaryAction: { slots in
            if let pid = pidAt(slots.first) { state.toggleExpanded(pid) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(shown: rows.count)
        }
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Picker("Сортировка", selection: $state.treeSort) {
                    ForEach(TreeSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Сортировка процессов внутри каждого уровня")

                ControlGroup {
                    Button { state.expandAll() } label: {
                        Label("Развернуть всё", systemImage: "rectangle.expand.vertical")
                    }
                    .help("Развернуть всё дерево")
                    Button { state.collapseAll() } label: {
                        Label("Свернуть всё", systemImage: "rectangle.compress.vertical")
                    }
                    .help("Свернуть до первого уровня")
                }
            }
        }
        .navigationTitle("Дерево процессов")
    }
}

struct TreeNameCell: View {
    let row: AppState.TreeRow
    /// Явно, а не через окружение — ячейки таблицы рендерятся в отдельных хостах.
    let state: AppState

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { state.toggleExpanded(row.record.pid) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(row.expanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(row.hasChildren ? 1 : 0)
            .disabled(!row.hasChildren)

            ProcessIcon(path: row.record.path, size: 16)
            Text(row.record.name).lineLimit(1)
            if row.hasChildren && !row.expanded {
                Text("\(row.totals.descendants)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                    .help("Скрыто потомков: \(row.totals.descendants)")
            }
            StateBadges(record: row.record, risk: state.risk(row.record))
        }
    }
}

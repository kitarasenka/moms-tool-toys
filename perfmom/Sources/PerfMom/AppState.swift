import AppKit
import Foundation
import Observation

enum SidebarSection: Hashable {
    case overview, processes, tree, history, startup, security
}

enum ProcessFilter: String, CaseIterable, Identifiable {
    case all = "Все"
    case mine = "Мои"
    case apps = "Приложения"
    case system = "Системные"
    var id: Self { self }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case summary = "Сводка"
    case chain = "Цепочка"
    case files = "Файлы"
    case modules = "Модули"
    case launch = "Запуск"
    var id: Self { self }
}

enum TreeSort: String, CaseIterable, Identifiable {
    case name = "Имя"
    case cpu = "ЦП"
    case memory = "Память"
    case network = "Сеть"
    case pid = "PID"
    var id: Self { self }
}

struct PendingAction: Identifiable {
    let id = UUID()
    let action: ProcessAction
    let pids: [pid_t]
    let name: String
    let rootPID: pid_t
    let childCount: Int
    let includesForeign: Bool

    var title: String {
        switch action {
        case .forceQuit: "Принудительно завершить «\(name)»?"
        default: childCount > 0 ? "Завершить «\(name)» и дочерние процессы?" : "Завершить «\(name)»?"
        }
    }

    var message: String {
        var parts: [String] = []
        switch action {
        case .forceQuit:
            parts.append("Процесс PID \(rootPID) будет остановлен немедленно (SIGKILL). Несохранённые данные будут потеряны.")
        default:
            parts.append("Процессу PID \(rootPID) будет отправлен запрос на завершение. Приложения смогут сохранить данные.")
        }
        if childCount > 0 { parts.append("Вместе с ним будет завершено дочерних процессов: \(childCount).") }
        if includesForeign { parts.append("Среди них есть системные процессы — может понадобиться пароль администратора.") }
        if pids.contains(getpid()) { parts.append("Это сам PerfMom — приложение закроется.") }
        return parts.joined(separator: "\n\n")
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var retryAsAdmin: PendingAction?
}

@MainActor @Observable
final class AppState {
    let monitor = Monitor()
    let startup = StartupStore()

    var section: SidebarSection = .processes
    var selectedPID: pid_t?
    var search = ""
    var filter: ProcessFilter = .all
    var showInspector = true
    var inspectorTab: InspectorTab = .summary
    var collapsed: Set<pid_t> = []
    var treeSort: TreeSort = .cpu
    var startupTab: StartupTab = .jobs

    var pendingAction: PendingAction?
    var alert: AlertInfo?

    // MARK: Безопасность

    /// Пути, которым пользователь доверяет (снимает ложные срабатывания). Хранится между запусками.
    var trustedPaths: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "trustedPaths") ?? []) {
        didSet { UserDefaults.standard.set(Array(trustedPaths).sorted(), forKey: "trustedPaths") }
    }

    func isTrusted(_ r: ProcessRecord) -> Bool { !r.path.isEmpty && trustedPaths.contains(r.path) }

    /// Уровень риска с учётом доверенных файлов.
    func risk(_ r: ProcessRecord) -> RiskLevel { isTrusted(r) ? .none : r.security.level }

    func toggleTrust(_ path: String) {
        guard !path.isEmpty else { return }
        if trustedPaths.contains(path) { trustedPaths.remove(path) } else { trustedPaths.insert(path) }
    }

    var riskyCount: Int { monitor.processes.filter { risk($0) >= .warning }.count }

    // MARK: Навигация

    func select(_ pid: pid_t, tab: InspectorTab? = nil) {
        selectedPID = pid
        showInspector = true
        if let tab { inspectorTab = tab }
    }

    func revealInTree(_ pid: pid_t) {
        for r in monitor.ancestry(of: pid) { collapsed.remove(r.pid) }
        selectedPID = pid
        section = .tree
    }

    func showChain(_ pid: pid_t) {
        select(pid, tab: .chain)
    }

    // MARK: Фильтрация

    func matchesSearch(_ r: ProcessRecord) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        if let n = Int32(q), n == r.pid { return true }
        return r.name.localizedCaseInsensitiveContains(q) || r.path.localizedCaseInsensitiveContains(q)
            || r.user.localizedCaseInsensitiveContains(q)
    }

    func matchesFilter(_ r: ProcessRecord) -> Bool {
        switch filter {
        case .all: true
        case .mine: r.uid == getuid()
        case .apps: monitor.appPIDs.contains(r.pid)
        case .system: r.uid != getuid()
        }
    }

    var filteredProcesses: [ProcessRecord] {
        monitor.processes.filter { matchesFilter($0) && matchesSearch($0) }
    }

    // MARK: Дерево

    struct TreeRow: Identifiable {
        let record: ProcessRecord
        let depth: Int
        let hasChildren: Bool
        let expanded: Bool
        let totals: SubtreeTotals
        /// Позиция в списке (см. комментарий к `Slot`): стабильная идентичность строк без пересоздания.
        var id: Int

    }

    func treeRows() -> [TreeRow] {
        let m = monitor
        var visible: Set<pid_t>?
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            var set = Set<pid_t>()
            for r in m.processes where matchesSearch(r) {
                for a in m.ancestry(of: r.pid) { set.insert(a.pid) }
            }
            visible = set
        }

        func sorted(_ pids: [pid_t]) -> [pid_t] {
            pids.sorted { a, b in
                guard let ra = m.byPID[a], let rb = m.byPID[b] else { return a < b }
                switch treeSort {
                case .name: return ra.name.localizedStandardCompare(rb.name) == .orderedAscending
                case .pid: return a < b
                case .cpu: return (m.subtree[a]?.cpu ?? 0) > (m.subtree[b]?.cpu ?? 0)
                case .memory: return (m.subtree[a]?.memory ?? 0) > (m.subtree[b]?.memory ?? 0)
                case .network: return (m.subtree[a]?.net ?? 0) > (m.subtree[b]?.net ?? 0)
                }
            }
        }

        var rows: [TreeRow] = []
        rows.reserveCapacity(m.processes.count)
        func visit(_ pid: pid_t, depth: Int) {
            guard let r = m.byPID[pid] else { return }
            if let visible, !visible.contains(pid) { return }
            let kids = m.children[pid] ?? []
            let expanded = visible != nil || !collapsed.contains(pid)
            rows.append(TreeRow(record: r, depth: depth, hasChildren: !kids.isEmpty, expanded: expanded,
                                totals: m.subtree[pid] ?? SubtreeTotals(cpu: r.cpu, memory: r.memory, net: r.netTotalRate, descendants: 0),
                                id: rows.count))
            if expanded {
                for k in sorted(kids) { visit(k, depth: depth + 1) }
            }
        }
        for root in sorted(m.roots) { visit(root, depth: 0) }
        return rows
    }

    func toggleExpanded(_ pid: pid_t) {
        if collapsed.contains(pid) { collapsed.remove(pid) } else { collapsed.insert(pid) }
    }

    func expandAll() { collapsed.removeAll() }

    func collapseAll() {
        // Оставляем раскрытыми корни, чтобы было видно хотя бы первый уровень.
        let rootSet = Set(monitor.roots)
        collapsed = Set(monitor.children.keys.filter { !rootSet.contains($0) })
    }

    // MARK: Управление процессами

    func request(_ action: ProcessAction, pid: pid_t? = nil, includeChildren: Bool = false) {
        guard let pid = pid ?? selectedPID, let rec = monitor.byPID[pid] else { return }
        if protectedPIDs.contains(pid) {
            alert = AlertInfo(title: "Этот процесс нельзя трогать",
                              message: pid == 0 ? "kernel_task — это ядро macOS." : "launchd — корневой процесс системы. Его остановка приведёт к перезагрузке.")
            return
        }
        let kids = includeChildren ? monitor.descendants(of: pid) : []
        let pids = kids + [pid]
        let myUID = getuid()
        let pending = PendingAction(
            action: action, pids: pids, name: rec.name, rootPID: pid, childCount: kids.count,
            includesForeign: pids.contains { (monitor.byPID[$0]?.uid ?? myUID) != myUID }
        )
        if action.needsConfirmation {
            pendingAction = pending
        } else {
            perform(pending)
        }
    }

    func perform(_ p: PendingAction) {
        let outcome = ProcessControl.send(p.action, to: p.pids)
        if !outcome.denied.isEmpty {
            let denied = PendingAction(action: p.action, pids: outcome.denied, name: p.name, rootPID: p.rootPID,
                                       childCount: max(0, outcome.denied.count - 1), includesForeign: true)
            alert = AlertInfo(
                title: "Недостаточно прав",
                message: "Процессов, принадлежащих другим пользователям: \(outcome.denied.count). Чтобы выполнить «\(p.action.title.lowercased())», нужен пароль администратора.",
                retryAsAdmin: denied
            )
        } else if !outcome.failed.isEmpty {
            alert = AlertInfo(title: "Не удалось выполнить действие",
                              message: outcome.failed.map { "PID \($0.0): \($0.1)" }.joined(separator: "\n"))
        }
        refreshSoon()
    }

    func performAsAdmin(_ p: PendingAction) {
        Task {
            do {
                try await ProcessControl.sendAsAdmin(p.action, to: p.pids)
            } catch AdminRunner.Failure.cancelled {
                return
            } catch {
                alert = AlertInfo(title: "Ошибка", message: error.localizedDescription)
            }
            refreshSoon()
        }
    }

    private func refreshSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            await monitor.refresh()
        }
    }

    // MARK: Утилиты Finder / буфер обмена

    static func revealInFinder(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

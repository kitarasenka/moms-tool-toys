import Darwin
import Foundation

enum ProcState: Sendable {
    case running, stopped, zombie, starting, unknown

    init(pStat: CChar) {
        switch pStat {
        case 1: self = .starting   // SIDL
        case 2, 3: self = .running // SRUN, SSLEEP
        case 4: self = .stopped    // SSTOP
        case 5: self = .zombie     // SZOMB
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .running: String(localized: "Активен")
        case .stopped: String(localized: "Приостановлен")
        case .zombie: String(localized: "Зомби (ожидает родителя)")
        case .starting: String(localized: "Запускается")
        case .unknown: "—"
        }
    }
}

struct ProcessRecord: Identifiable, Equatable, Sendable {
    let pid: pid_t
    var id: pid_t { pid }
    var ppid: pid_t
    var uid: uid_t
    var user: String
    var name: String
    var path: String
    var startTime: Date?
    var state: ProcState

    /// % от одного ядра (как в Мониторинге системы: 100% = одно ядро полностью).
    var cpu: Double = 0
    var cpuTime: Double = 0
    /// Физический след памяти (phys_footprint), для закрытых процессов — RSS из ps.
    var memory: UInt64 = 0
    var threads: Int?
    var diskRead: Double?
    var diskWrite: Double?
    var diskReadTotal: UInt64?
    var diskWriteTotal: UInt64?
    /// Сетевой трафик (из nettop). nil — данные недоступны.
    var netIn: Double?
    var netOut: Double?
    var netInTotal: UInt64?
    var netOutTotal: UInt64?
    /// Процесс другого пользователя — подробности доступны только с правами администратора.
    var restricted = false
    /// Эвристическая оценка риска (заполняет SecurityAnalyzer).
    var security = SecurityAssessment()

    var isSystem: Bool { uid < 500 }

    // Ключи сортировки для Table (опциональные значения не Comparable).
    var threadsSort: Int { threads ?? -1 }
    var diskReadSort: Double { diskRead ?? -1 }
    var diskWriteSort: Double { diskWrite ?? -1 }
    var netInSort: Double { netIn ?? -1 }
    var netOutSort: Double { netOut ?? -1 }
    var netTotalRate: Double { (netIn ?? 0) + (netOut ?? 0) }
}

struct SubtreeTotals: Sendable {
    var cpu: Double
    var memory: UInt64
    var net: Double
    var descendants: Int
}

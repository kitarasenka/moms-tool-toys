import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class Monitor {
    static let historyCapacity = 90

    private(set) var processes: [ProcessRecord] = []
    private(set) var byPID: [pid_t: ProcessRecord] = [:]
    private(set) var children: [pid_t: [pid_t]] = [:]
    private(set) var roots: [pid_t] = []
    private(set) var subtree: [pid_t: SubtreeTotals] = [:]
    private(set) var appPIDs: Set<pid_t> = []
    private(set) var totalThreads = 0
    private(set) var system = SystemSnapshot()
    private(set) var lastUpdate: Date?

    private(set) var cpuUserHistory: [Double] = []
    private(set) var cpuSystemHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var netInHistory: [Double] = []
    private(set) var netOutHistory: [Double] = []
    private(set) var diskReadHistory: [Double] = []
    private(set) var diskWriteHistory: [Double] = []
    private(set) var processCPUHistory: [pid_t: [Double]] = [:]
    private(set) var processMemoryHistory: [pid_t: [Double]] = [:]
    private(set) var processNetInHistory: [pid_t: [Double]] = [:]
    private(set) var processNetOutHistory: [pid_t: [Double]] = [:]

    let machine: MachineInfo
    private let demo: Bool
    var interval: Double = 2
    var paused = false

    @ObservationIgnored private let processSampler = ProcessSampler()
    @ObservationIgnored private let systemSampler = SystemSampler()
    @ObservationIgnored private let securityAnalyzer = SecurityAnalyzer()
    @ObservationIgnored private let queue = DispatchQueue(label: "perfmom.sampler", qos: .utility)
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            machine = MachineInfo(model: "MacBook Air", cpuBrand: "Apple M2", physicalCores: 8, logicalCores: 8,
                                  performanceCores: 4, efficiencyCores: 4, memory: 8_000_000_000,
                                  osVersion: "macOS 15.6", hostName: "MacBook-Air")
            let browser = ProcessRecord(pid: 4242, ppid: 1, uid: 501, user: "demo", name: "Safari",
                                        path: "", startTime: nil, state: .running, cpu: 12.5, memory: 402_000_000, threads: 8)
            let desktop = ProcessRecord(pid: 4243, ppid: 1, uid: 501, user: "demo", name: "Finder",
                                        path: "", startTime: nil, state: .running, cpu: 1.4, memory: 85_000_000, threads: 4)
            let snapshot = SystemSnapshot(cpuUser: 14, cpuSystem: 4, perCore: [18, 24, 6, 10, 7, 2, 4, 9],
                                          memTotal: machine.memory, memApp: 3_400_000_000, memWired: 580_000_000,
                                          memCompressed: 220_000_000, memCached: 800_000_000, memFree: 3_000_000_000,
                                          netIn: 240_000, netOut: 13_000, diskRead: 1_200_000, diskWrite: 450_000)
            apply([browser, desktop], snapshot)
        } else {
            machine = .current
        }
    }

    func start() {
        guard !demo, loop == nil else { return }
        NetworkMonitor.shared.start()
        loop = Task { [weak self] in
            await self?.refresh()
            // Второй замер быстро, чтобы проценты CPU появились почти сразу.
            try? await Task.sleep(for: .milliseconds(700))
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused { await self.refresh() }
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    func refresh() async {
        guard !demo, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let ps = processSampler, ss = systemSampler, sa = securityAnalyzer, q = queue
        let (procs, sys) = await withCheckedContinuation { (cont: CheckedContinuation<([ProcessRecord], SystemSnapshot), Never>) in
            q.async {
                var procs = ps.sample()
                sa.annotate(&procs)
                cont.resume(returning: (procs, ss.sample()))
            }
        }
        // Без анимации: иначе NSTableView анимирует перестановку сотен строк на каждом тике.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { apply(procs, sys) }
    }

    private func apply(_ procs: [ProcessRecord], _ sys: SystemSnapshot) {
        // Первый замер без дельт (все проценты нулевые) в историю не пишем.
        if !demo, lastUpdate != nil { HistoryRecorder.shared.ingest(system: sys, processes: procs) }
        let map = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var kids: [pid_t: [pid_t]] = [:]
        var rootList: [pid_t] = []
        var threads = 0
        for p in procs {
            threads += p.threads ?? 0
            if p.ppid != p.pid, map[p.ppid] != nil {
                kids[p.ppid, default: []].append(p.pid)
            } else {
                rootList.append(p.pid)
            }
        }

        var totals: [pid_t: SubtreeTotals] = [:]
        func total(_ pid: pid_t) -> SubtreeTotals {
            if let t = totals[pid] { return t }
            let r = map[pid]
            var t = SubtreeTotals(cpu: r?.cpu ?? 0, memory: r?.memory ?? 0, net: r?.netTotalRate ?? 0, descendants: 0)
            for k in kids[pid] ?? [] {
                let c = total(k)
                t.cpu += c.cpu
                t.memory += c.memory
                t.net += c.net
                t.descendants += c.descendants + 1
            }
            totals[pid] = t
            return t
        }
        for r in rootList { _ = total(r) }

        var cpuHist: [pid_t: [Double]] = [:]
        var memHist: [pid_t: [Double]] = [:]
        var inHist: [pid_t: [Double]] = [:]
        var outHist: [pid_t: [Double]] = [:]
        cpuHist.reserveCapacity(procs.count)
        memHist.reserveCapacity(procs.count)
        for p in procs {
            cpuHist[p.pid] = Self.appending(processCPUHistory[p.pid] ?? [], p.cpu, limit: 60)
            memHist[p.pid] = Self.appending(processMemoryHistory[p.pid] ?? [], Double(p.memory), limit: 60)
            // Историю сети храним только для процессов, которые когда-либо ходили в сеть.
            if (p.netInTotal ?? 0) + (p.netOutTotal ?? 0) > 0 || processNetInHistory[p.pid] != nil {
                inHist[p.pid] = Self.appending(processNetInHistory[p.pid] ?? [], p.netIn ?? 0, limit: 60)
                outHist[p.pid] = Self.appending(processNetOutHistory[p.pid] ?? [], p.netOut ?? 0, limit: 60)
            }
        }

        appPIDs = demo ? Set(procs.map(\.pid)) : Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map(\.processIdentifier))

        processes = procs
        byPID = map
        children = kids
        roots = rootList
        subtree = totals
        totalThreads = threads
        system = sys
        processCPUHistory = cpuHist
        processMemoryHistory = memHist
        processNetInHistory = inHist
        processNetOutHistory = outHist
        lastUpdate = Date()

        let cap = Self.historyCapacity
        cpuUserHistory = Self.appending(cpuUserHistory, sys.cpuUser, limit: cap)
        cpuSystemHistory = Self.appending(cpuSystemHistory, sys.cpuSystem, limit: cap)
        memoryHistory = Self.appending(memoryHistory, Double(sys.memUsed), limit: cap)
        netInHistory = Self.appending(netInHistory, sys.netIn, limit: cap)
        netOutHistory = Self.appending(netOutHistory, sys.netOut, limit: cap)
        diskReadHistory = Self.appending(diskReadHistory, sys.diskRead, limit: cap)
        diskWriteHistory = Self.appending(diskWriteHistory, sys.diskWrite, limit: cap)
    }

    private static func appending(_ a: [Double], _ v: Double, limit: Int) -> [Double] {
        var a = a
        a.append(v)
        if a.count > limit { a.removeFirst(a.count - limit) }
        return a
    }

    // MARK: Связи процессов

    /// Цепочка от корня (kernel_task/launchd) до процесса включительно.
    func ancestry(of pid: pid_t) -> [ProcessRecord] {
        var chain: [ProcessRecord] = []
        var seen = Set<pid_t>()
        var current: pid_t? = pid
        while let c = current, let r = byPID[c], seen.insert(c).inserted {
            chain.append(r)
            current = r.ppid == r.pid ? nil : r.ppid
        }
        return chain.reversed()
    }

    /// Все потомки, самые глубокие первыми — в таком порядке их и нужно завершать.
    func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        func visit(_ p: pid_t) {
            for k in children[p] ?? [] {
                visit(k)
                result.append(k)
            }
        }
        visit(pid)
        return result
    }
}

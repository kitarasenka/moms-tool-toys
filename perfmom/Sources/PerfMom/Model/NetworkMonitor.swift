import Darwin
import Foundation

/// Сетевой трафик по процессам. Публичного API для этого в macOS нет; системный `nettop` получает
/// данные из NetworkStatistics (работает без root и видит все процессы). Держим один экземпляр
/// `nettop` запущенным в потоковом режиме — разовый вызов занимает ~5 с.
/// `nettop` буферизует вывод в pipe, поэтому запускаем его через `script` (псевдотерминал) —
/// так снимок приходит сразу, раз в секунду.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    struct Stat: Sendable {
        var bytesIn: UInt64
        var bytesOut: UInt64
        var rateIn: Double
        var rateOut: Double
    }

    private let lock = NSLock()
    private var stats: [pid_t: Stat] = [:]
    private var available = false

    // Состояние парсера (только в readabilityHandler).
    private var buffer = ""
    private var block: [pid_t: (UInt64, UInt64)] = [:]
    private var lastBlock: [pid_t: (UInt64, UInt64)] = [:]
    private var lastBlockTime: Double = 0
    private var blockTime: Double = 0

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stopped = false
    private var restarts = 0

    /// Снимок: `nil`, если nettop недоступен (тогда в UI показываем «—», а не нули).
    func snapshot() -> [pid_t: Stat]? {
        lock.lock()
        defer { lock.unlock() }
        return available ? stats : nil
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil, !stopped else { return }
        launch()
    }

    func stop() {
        lock.lock()
        stopped = true
        let p = process
        process = nil
        lock.unlock()
        p?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        if let p, p.isRunning { p.terminate() }
    }

    /// Вызывается под lock.
    private func launch() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/nettop") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", "/usr/bin/nettop", "-P", "-L", "0", "-s", "1", "-x",
                       "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        // stdin должен оставаться открытым: при EOF (например, /dev/null) nettop в псевдотерминале
        // начинает крутиться в цикле опроса ввода и съедает 50–130% ЦП.
        let input = Pipe()
        p.standardInput = input
        stdinPipe = input

        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            self?.consume(String(decoding: data, as: UTF8.self))
        }
        p.terminationHandler = { [weak self] _ in self?.handleExit() }

        do {
            try p.run()
            process = p
        } catch {
            process = nil
        }
    }

    private func handleExit() {
        lock.lock()
        process = nil
        available = false
        let shouldRestart = !stopped && restarts < 5
        restarts += 1
        lock.unlock()
        guard shouldRestart else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.process == nil, !self.stopped { self.launch() }
            self.lock.unlock()
        }
    }

    private func consume(_ text: String) {
        // Псевдотерминал отдаёт «\r\n», а в Swift это один Character — поиск "\n" его не находит.
        buffer += text.replacingOccurrences(of: "\r", with: "")
        guard let lastNewline = buffer.lastIndex(of: "\n") else { return }
        let complete = buffer[..<lastNewline]
        buffer = String(buffer[buffer.index(after: lastNewline)...])

        for raw in complete.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains(",bytes_in,bytes_out") {
                // Заголовок = начало нового снимка; предыдущий становится базой для скоростей.
                if !block.isEmpty {
                    lastBlock = block
                    lastBlockTime = blockTime
                }
                block = [:]
                blockTime = MachTime.now()
                continue
            }
            // Формат: «имя.pid,bytes_in,bytes_out,» — имя может содержать точки и запятые.
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            let n = fields.count - (fields.last?.isEmpty == true ? 1 : 0)
            guard n >= 3, let bin = UInt64(fields[n - 2]), let bout = UInt64(fields[n - 1]) else { continue }
            let name = fields[0..<(n - 2)].joined(separator: ",")
            guard let dot = name.lastIndex(of: "."), let pid = pid_t(name[name.index(after: dot)...]) else { continue }
            let prev = block[pid] ?? (0, 0)
            block[pid] = (prev.0 + bin, prev.1 + bout)
        }
        // Публикуем то, что уже пришло из текущего снимка (обычно он приходит целиком одним куском).
        if !block.isEmpty { publish() }
    }

    private func publish() {
        let dt = lastBlockTime > 0 ? blockTime - lastBlockTime : 0
        var next: [pid_t: Stat] = [:]
        next.reserveCapacity(block.count)
        for (pid, v) in block {
            var s = Stat(bytesIn: v.0, bytesOut: v.1, rateIn: 0, rateOut: 0)
            if dt > 0.2, let p = lastBlock[pid] {
                if v.0 >= p.0 { s.rateIn = Double(v.0 - p.0) / dt }
                if v.1 >= p.1 { s.rateOut = Double(v.1 - p.1) / dt }
            }
            next[pid] = s
        }
        lock.lock()
        stats = next
        available = true
        restarts = 0
        lock.unlock()
    }
}

import Darwin
import Foundation

// «Энергопотребление» процессов — та же оценка, что в Мониторинге системы (колонка POWER у `top`).
// Это относительная величина (не ватты): ~1 ≈ процент одного ядра плюс пробуждения, GPU и т. п.

struct TopProcess: Sendable, Equatable {
    var pid: Int32
    var command: String
    var power: Double
}

struct AppEnergy: Identifiable, Sendable, Equatable {
    /// Путь к .app или «proc:имя».
    var id: String
    var name: String
    var bundlePath: String?
    var power: Double
    var processCount: Int
}

enum EnergySampler {
    /// Два замера с интервалом 1 с: первый у `top` всегда нулевой, считаем по второму.
    static func sample(limit: Int = 15) -> [AppEnergy] {
        let r = Shell.run("/usr/bin/top", ["-l", "2", "-s", "1", "-stats", "pid,command,power", "-o", "power", "-n", "20"],
                          timeout: 20)
        let procs = parseTop(r.text).filter { $0.pid != r.pid }  // сам `top` не считаем
        return Array(group(procs, path: processPath).prefix(limit))
    }

    /// Строки последнего замера: «PID COMMAND POWER». Имя команды у top обрезано до 16 символов
    /// (а кириллица — посреди буквы), поэтому настоящее имя потом берём по PID.
    static func parseTop(_ text: String) -> [TopProcess] {
        let lines = text.components(separatedBy: .newlines)
        guard let header = lines.lastIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("PID") && t.hasSuffix("POWER")
        }) else { return [] }
        var out: [TopProcess] = []
        for line in lines[(header + 1)...] {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3, let pid = Int32(parts[0]), let power = Double(parts[parts.count - 1]) else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                break
            }
            let command = parts[1..<(parts.count - 1)].joined(separator: " ")
            out.append(TopProcess(pid: pid, command: command, power: power))
        }
        return out
    }

    /// Складывает helper-процессы в их приложение (по внешнему .app в пути) и сортирует по убыванию.
    static func group(_ procs: [TopProcess], path: (Int32) -> String?) -> [AppEnergy] {
        var byKey: [String: AppEnergy] = [:]
        for p in procs {
            let exe = path(p.pid)
            let bundle = exe.flatMap(outermostApp)
            let key: String, name: String
            if let bundle {
                key = bundle
                name = FileManager.default.displayName(atPath: bundle).replacingOccurrences(of: ".app", with: "")
            } else {
                name = exe.map { ($0 as NSString).lastPathComponent } ?? cleanCommand(p.command)
                key = "proc:" + name
            }
            byKey[key, default: AppEnergy(id: key, name: name, bundlePath: bundle, power: 0, processCount: 0)].power += p.power
            byKey[key]?.processCount += 1
        }
        return byKey.values.filter { $0.power > 0 }.sorted { $0.power > $1.power }
    }

    /// «/Applications/Google Chrome.app/Contents/Frameworks/…/Helper (Renderer).app/…» → «/Applications/Google Chrome.app».
    static func outermostApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
        else { return nil }
        return String(path[..<r.upperBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .prepending("/")
    }

    static func processPath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN.
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// Убираем «битый» хвост от обрезанной посреди буквы кириллицы.
    private static func cleanCommand(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{FFFD}", with: "").trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    func prepending(_ p: String) -> String { hasPrefix(p) ? self : p + self }
}

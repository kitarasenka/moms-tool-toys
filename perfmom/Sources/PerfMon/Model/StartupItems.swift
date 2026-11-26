import AppKit
import Carbon
import Darwin
import Foundation

// MARK: - Фоновые агенты и службы launchd

enum JobScope: Int, CaseIterable, Sendable {
    case userAgent, globalAgent, daemon

    var directory: String {
        switch self {
        case .userAgent: NSHomeDirectory() + "/Library/LaunchAgents"
        case .globalAgent: "/Library/LaunchAgents"
        case .daemon: "/Library/LaunchDaemons"
        }
    }

    var title: String {
        switch self {
        case .userAgent: "Агент пользователя"
        case .globalAgent: "Агент для всех пользователей"
        case .daemon: "Системная служба (root)"
        }
    }

    var short: String {
        switch self {
        case .userAgent: "Пользователь"
        case .globalAgent: "Все пользователи"
        case .daemon: "Система"
        }
    }

    var needsAdmin: Bool { self == .daemon }
}

struct LaunchJob: Identifiable, Sendable {
    var id: String { plistPath }
    let label: String
    let plistPath: String
    let scope: JobScope
    let program: String?
    let arguments: [String]
    /// Что реально запускается: для обёрток (`open X.app`, `sh script.sh`) — X.app / script.sh.
    let target: String?
    /// Имя обёртки (open, sh, python3…), если служба запускает цель через неё.
    let wrapper: String?
    let trigger: String
    let startsAutomatically: Bool
    let disabledInPlist: Bool
    /// Отметка launchd (`launchctl enable/disable`): true — включена, false — выключена, nil — нет отметки.
    let override: Bool?
    /// PID из `launchctl list` (только для домена пользователя).
    let pid: pid_t?
    let programExists: Bool
    let signing: SigningInfo?

    var enabled: Bool { override ?? !disabledInPlist }

    var displayCommand: String {
        guard let target else { return "—" }
        return wrapper.map { "\($0) → \(target)" } ?? target
    }

    var isScript: Bool {
        guard let target else { return false }
        return ["sh", "bash", "zsh", "py", "rb", "pl", "js", "command", "scpt", "applescript"]
            .contains((target as NSString).pathExtension.lowercased())
    }

    var vendor: String {
        guard target != nil else { return "—" }
        if !programExists { return "Файл не найден" }
        if isScript { return "Скрипт (\(wrapper ?? "интерпретатор"))" }
        guard let s = signing else { return "Не удалось проверить" }
        if let team = s.teamID, !s.isApple, let auth = s.authority {
            // «Developer ID Application: Google LLC (EQHXZ8M8AV)» → «Google LLC»
            let name = auth.replacingOccurrences(of: "Developer ID Application: ", with: "")
                .replacingOccurrences(of: " (\(team))", with: "")
            return name
        }
        return s.summary
    }
}

enum StartupScanner {
    static func scanJobs() -> [LaunchJob] {
        let uid = getuid()
        let guiOverrides = parseDisabled(launchctl(["print-disabled", "gui/\(uid)"]) ?? "")
        let systemOverrides = parseDisabled(launchctl(["print-disabled", "system"]) ?? "")
        let running = parseList(launchctl(["list"]) ?? "")
        var signingCache: [String: SigningInfo?] = [:]
        var jobs: [LaunchJob] = []
        let fm = FileManager.default

        for scope in JobScope.allCases {
            guard let files = try? fm.contentsOfDirectory(atPath: scope.directory) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let path = scope.directory + "/" + file
                guard let data = fm.contents(atPath: path),
                      let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                else { continue }

                let label = (dict["Label"] as? String) ?? String(file.dropLast(6))
                let args = (dict["ProgramArguments"] as? [String]) ?? []
                let program = (dict["Program"] as? String) ?? args.first
                let (target, wrapper) = resolveTarget(program: program, args: args)
                let exists = target.map { fm.fileExists(atPath: $0) } ?? false

                var signing: SigningInfo?
                if let target, exists {
                    if let cached = signingCache[target] {
                        signing = cached
                    } else {
                        signing = DetailsLoader.signing(target)
                        signingCache[target] = signing
                    }
                }

                let (trigger, auto) = describeTrigger(dict, scope: scope)
                jobs.append(LaunchJob(
                    label: label, plistPath: path, scope: scope, program: program, arguments: args,
                    target: target, wrapper: wrapper,
                    trigger: trigger, startsAutomatically: auto,
                    disabledInPlist: (dict["Disabled"] as? Bool) ?? false,
                    override: scope == .daemon ? systemOverrides[label] : guiOverrides[label],
                    pid: scope == .daemon ? nil : running[label],
                    programExists: exists, signing: signing
                ))
            }
        }
        return jobs.sorted {
            $0.scope.rawValue != $1.scope.rawValue ? $0.scope.rawValue < $1.scope.rawValue
                : $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private static let wrappers: Set<String> = ["open", "sh", "bash", "zsh", "env", "python", "python3",
                                                "perl", "ruby", "node", "osascript"]
    private static let searchPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"]

    /// Разворачивает обёртки и ищет команды без пути в PATH, иначе `open`/`sh` выглядели бы «удалёнными».
    static func resolveTarget(program: String?, args: [String]) -> (String?, String?) {
        guard let program else { return (nil, nil) }
        let base = (program as NSString).lastPathComponent
        if wrappers.contains(base), let t = args.dropFirst().first(where: { $0.hasPrefix("/") }) {
            return (t, base)
        }
        if !program.hasPrefix("/") {
            if let found = searchPath.map({ $0 + "/" + program }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return (found, nil)
            }
        }
        return (program, nil)
    }

    private static func describeTrigger(_ d: [String: Any], scope: JobScope) -> (String, Bool) {
        if d.isEmpty { return ("Пустой файл — ничего не запускает", false) }
        let keepAlive: Bool = {
            if let b = d["KeepAlive"] as? Bool { return b }
            return d["KeepAlive"] is [String: Any]
        }()
        let runAtLoad = (d["RunAtLoad"] as? Bool) ?? false
        let atStart = scope == .daemon ? "При загрузке системы" : "При входе в систему"
        if keepAlive { return (runAtLoad ? "\(atStart), постоянно" : "Постоянно (перезапускается)", true) }
        if runAtLoad { return (atStart, true) }
        if d["StartInterval"] != nil || d["StartCalendarInterval"] != nil { return ("По расписанию", true) }
        if d["WatchPaths"] != nil || d["QueueDirectories"] != nil { return ("При изменении файлов", false) }
        if d["MachServices"] != nil || d["Sockets"] != nil { return ("По запросу других программ", false) }
        return ("Вручную", false)
    }

    /// `"label" => disabled|enabled` (на старых системах — true|false, где true = выключено).
    static func parseDisabled(_ text: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            guard let arrow = line.range(of: "=>") else { continue }
            let label = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            switch value {
            case "disabled", "true": out[label] = false
            case "enabled", "false": out[label] = true
            default: break
            }
        }
        return out
    }

    /// `launchctl list`: «PID\tStatus\tLabel».
    static func parseList(_ text: String) -> [String: pid_t] {
        var out: [String: pid_t] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t")
            guard f.count >= 3, let pid = pid_t(f[0]) else { continue }
            out[String(f[2])] = pid
        }
        return out
    }

    static func launchctl(_ args: [String]) -> String? {
        try? LaunchControl.run(args)
    }
}

enum LaunchControl {
    enum Failure: LocalizedError {
        case command(String)
        case unsafe

        var errorDescription: String? {
            switch self {
            case .command(let m): m
            case .unsafe: "Метка или путь службы содержат недопустимые символы — управлять ей через PerfMon небезопасно."
            }
        }
    }

    @discardableResult
    static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.command(msg.isEmpty ? "launchctl \(args.joined(separator: " ")): код \(p.terminationStatus)" : msg)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Включение/выключение переживает перезагрузку: `launchctl enable/disable` пишет отметку в базу launchd.
    /// Дополнительно служба сразу запускается (`bootstrap`) или останавливается (`bootout`).
    static func setEnabled(_ job: LaunchJob, enabled: Bool) async throws {
        switch job.scope {
        case .userAgent, .globalAgent:
            let domain = "gui/\(getuid())"
            try await Task.detached {
                if enabled {
                    try run(["enable", "\(domain)/\(job.label)"])
                    _ = try? run(["bootstrap", domain, job.plistPath]) // «уже загружена» — не ошибка
                } else {
                    try run(["disable", "\(domain)/\(job.label)"])
                    _ = try? run(["bootout", "\(domain)/\(job.label)"])
                }
            }.value
        case .daemon:
            // Команда уходит в shell от root, поэтому пропускаем только «скучные» символы.
            guard isSafe(job.label), isSafe(job.plistPath), job.plistPath.hasPrefix("/Library/LaunchDaemons/") else {
                throw Failure.unsafe
            }
            let cmd = enabled
                ? "/bin/launchctl enable system/\(job.label); /bin/launchctl bootstrap system \(job.plistPath) 2>/dev/null; true"
                : "/bin/launchctl disable system/\(job.label); /bin/launchctl bootout system/\(job.label) 2>/dev/null; true"
            _ = try await AdminRunner.run(cmd)
        }
    }

    /// Только для агентов пользователя: выгрузить и переместить plist в Корзину (можно восстановить).
    static func moveToTrash(_ job: LaunchJob) throws {
        guard job.scope == .userAgent else { return }
        _ = try? run(["bootout", "gui/\(getuid())/\(job.label)"])
        try FileManager.default.trashItem(at: URL(fileURLWithPath: job.plistPath), resultingItemURL: nil)
    }

    private static func isSafe(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-/".contains($0)) }
    }
}

// MARK: - Объекты входа («Открывать при входе» в Системных настройках)

struct LoginItem: Identifiable, Sendable {
    var id: String { path.isEmpty ? name : path }
    let name: String
    let path: String
    let hidden: Bool
}

enum LoginAccess: Equatable {
    case unknown, needsConsent, denied, granted
    case failed(String)
}

/// Список объектов входа доступен только через System Events (AppleScript).
/// macOS один раз спрашивает разрешение «PerfMon хочет управлять System Events».
enum LoginItemsService {
    static let systemEventsID = "com.apple.systemevents"

    /// Проверка разрешения без показа диалога (ask = false) или с запросом (ask = true). Блокирует поток.
    static func determineAccess(ask: Bool) -> LoginAccess {
        let target = NSAppleEventDescriptor(bundleIdentifier: systemEventsID)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .needsConsent
        case OSStatus(procNotFound): return .unknown
        default: return .failed("Код \(status)")
        }
    }

    /// AEDeterminePermission работает только с запущенным System Events — запускаем его в фоне.
    @MainActor
    static func launchSystemEvents() async {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: systemEventsID).isEmpty { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemEventsID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    @MainActor
    static func list() throws -> [LoginItem] {
        let result = try run("""
        tell application "System Events"
            set out to {}
            repeat with li in login items
                set end of out to {name of li, path of li, hidden of li}
            end repeat
            return out
        end tell
        """)
        var items: [LoginItem] = []
        let count = result.numberOfItems
        guard count > 0 else { return [] }
        for i in 1...count {
            guard let row = result.atIndex(i), row.numberOfItems >= 3 else { continue }
            items.append(LoginItem(
                name: row.atIndex(1)?.stringValue ?? "",
                path: row.atIndex(2)?.stringValue ?? "",
                hidden: row.atIndex(3)?.booleanValue ?? false
            ))
        }
        return items
    }

    @MainActor
    static func add(path: String, hidden: Bool = false) throws {
        try run("tell application \"System Events\" to make login item at end with properties {path:\"\(escape(path))\", hidden:\(hidden)}")
    }

    @MainActor
    static func remove(_ item: LoginItem) throws {
        try run("tell application \"System Events\" to delete (every login item whose \(selector(item)))")
    }

    @MainActor
    static func setHidden(_ item: LoginItem, hidden: Bool) throws {
        try run("tell application \"System Events\" to set hidden of (every login item whose \(selector(item))) to \(hidden)")
    }

    private static func selector(_ item: LoginItem) -> String {
        item.path.isEmpty ? "name is \"\(escape(item.name))\"" : "path is \"\(escape(item.path))\""
    }

    /// Экранирование для строкового литерала AppleScript.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @MainActor @discardableResult
    private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw LaunchControl.Failure.command("Некорректный скрипт") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg = (error[NSAppleScript.errorMessage] as? String) ?? "Ошибка AppleScript \(code)"
            throw LaunchControl.Failure.command(code == -1743 ? "Нет разрешения управлять System Events." : msg)
        }
        return result
    }
}

enum SystemSettingsLinks {
    static let loginItems = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    static let automation = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}

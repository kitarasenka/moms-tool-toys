import Darwin
import Foundation
import Security

// Эвристическая оценка риска процессов. Это не антивирус: сигнатур вредоносов нет,
// оцениваются признаки, типичные для вредоносного ПО на macOS. Ложные срабатывания
// (особенно у самосборных инструментов разработчика) снимаются кнопкой «Доверять».

enum RiskLevel: Int, Comparable, CaseIterable, Sendable {
    case none, info, warning, danger

    static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .none: "Нет замечаний"
        case .info: "Замечание"
        case .warning: "Обратите внимание"
        case .danger: "Подозрительно"
        }
    }

    var symbol: String {
        switch self {
        case .none: "checkmark.shield"
        case .info: "info.circle"
        case .warning: "exclamationmark.shield"
        case .danger: "xmark.shield.fill"
        }
    }
}

struct SecurityFinding: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let weight: Int

    var level: RiskLevel { weight >= 4 ? .danger : (weight >= 2 ? .warning : .info) }
}

struct SecurityAssessment: Equatable, Sendable {
    var findings: [SecurityFinding] = []
    var signer = "Проверяется…"
    var isPlatform = false
    var hardenedRuntime = false

    var score: Int { findings.reduce(0) { $0 + $1.weight } }
    var level: RiskLevel { score >= 4 ? .danger : (score >= 2 ? .warning : (score >= 1 ? .info : .none)) }
}

/// Статус подписи работающего процесса из ядра (csops). Работает без root для всех процессов.
enum KernelCodeSigning {
    private typealias CsopsFn = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
    private static let csops: CsopsFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else { return nil }
        return unsafeBitCast(sym, to: CsopsFn.self)
    }()

    static let valid: UInt32 = 0x0000_0001
    static let runtime: UInt32 = 0x0001_0000
    static let platformBinary: UInt32 = 0x0400_0000
    static let debugged: UInt32 = 0x1000_0000

    static func flags(_ pid: pid_t) -> UInt32? {
        guard let csops else { return nil }
        var flags: UInt32 = 0
        return csops(pid, 0 /* CS_OPS_STATUS */, &flags, MemoryLayout<UInt32>.size) == 0 ? flags : nil
    }
}

final class SecurityAnalyzer: @unchecked Sendable {
    private var signingCache: [String: SigningInfo?] = [:]
    private var quarantineCache: [String: Bool] = [:]
    private var injectionCache: [String: Bool] = [:]
    private var jobsByTarget: [String: LaunchJob] = [:]
    private var lastJobsScan: Double = 0
    private let myUID = getuid()
    private let home = NSHomeDirectory()

    /// Новых путей для проверки подписи за один проход — чтобы первый замер не подвисал.
    private let signingBudget = 40

    /// Признаки, не меняющиеся за жизнь процесса (подпись, путь, имя, родитель, автозагрузка), считаются
    /// один раз на процесс; кэш сбрасывается раз в минуту. На каждом тике — только статус из ядра, сеть и ЦП.
    private struct Cached {
        var base: SecurityAssessment
        var noCertificate: Bool
        /// false — подпись файла ещё не проверена (кончился бюджет), пересчитать на следующем тике.
        var complete: Bool
    }

    private var cache: [String: Cached] = [:]

    func annotate(_ procs: inout [ProcessRecord]) {
        if refreshJobsIfNeeded() { cache.removeAll(keepingCapacity: true) }
        var budget = signingBudget
        var byPID: [pid_t: ProcessRecord]?
        var next: [String: Cached] = [:]
        next.reserveCapacity(procs.count)

        for i in procs.indices {
            let r = procs[i]
            guard r.pid > 0, r.state != .zombie else {
                procs[i].security = SecurityAssessment(signer: r.pid == 0 ? "Ядро macOS" : "—", isPlatform: true)
                continue
            }
            let key = "\(r.pid)-\(r.startTime?.timeIntervalSince1970 ?? 0)"
            let entry: Cached
            if let c = cache[key], c.complete {
                entry = c
            } else {
                if byPID == nil { byPID = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a }) }
                entry = staticAssessment(r, byPID: byPID ?? [:], budget: &budget)
            }
            next[key] = entry

            var a = entry.base
            func add(_ id: String, _ title: String, _ detail: String, _ weight: Int) {
                a.findings.append(SecurityFinding(id: id, title: title, detail: detail, weight: weight))
            }
            let flags = KernelCodeSigning.flags(r.pid)
            if let f = flags, f & KernelCodeSigning.valid == 0 {
                add("invalid", "Подпись недействительна",
                    "Ядро пометило код процесса как изменённый после запуска — так бывает при внедрении кода.", 4)
            }
            if let f = flags, f & KernelCodeSigning.debugged != 0, !a.isPlatform {
                add("debugged", "Подключён отладчик", "К процессу подключался отладчик или его память изменялась извне.", 1)
            }
            if entry.noCertificate {
                if (r.netInTotal ?? 0) + (r.netOutTotal ?? 0) > 0 {
                    add("network", "Сетевая активность без сертификата",
                        "Программа без подписи разработчика обменивается данными по сети.", 1)
                }
                if r.cpu >= 80 {
                    add("cpu", "Высокая нагрузка без сертификата",
                        "Неподписанная программа загружает процессор на \(Fmt.percent(r.cpu)) % — так выглядят, например, майнеры.", 1)
                }
            }
            procs[i].security = a
        }
        cache = next
    }

    private func staticAssessment(_ r: ProcessRecord, byPID: [pid_t: ProcessRecord], budget: inout Int) -> Cached {
        var a = SecurityAssessment()
        func add(_ id: String, _ title: String, _ detail: String, _ weight: Int) {
            a.findings.append(SecurityFinding(id: id, title: title, detail: detail, weight: weight))
        }
        let fm = FileManager.default
        let flags = KernelCodeSigning.flags(r.pid)
        a.isPlatform = flags.map { $0 & KernelCodeSigning.platformBinary != 0 } ?? false
        a.hardenedRuntime = flags.map { $0 & KernelCodeSigning.runtime != 0 } ?? false

        // Ядро не отдаёт путь (ENOENT), если файл удалён до первого замера; если позже —
        // ловим проверкой существования при ежеминутном пересчёте.
        if r.path.isEmpty || !fm.fileExists(atPath: r.path) {
            add("deleted", "Исполняемый файл удалён",
                "Процесс «\(r.name)» работает, но его файла больше нет на диске — частый приём, чтобы замести следы.", 4)
        }
        checkParent(r, byPID: byPID, add: add)

        if a.isPlatform {
            // Копия системной утилиты под чужим именем/в чужом месте сохраняет подпись Apple,
            // поэтому расположение и имя проверяем и у платформенных бинарников.
            a.signer = "Apple (система)"
            checkLocation(r, noCertificate: false, add: add)
            if Self.systemNames.contains(r.name) || r.name.lowercased().hasPrefix("com.apple."),
               !Self.systemDirs.contains(where: { r.path.hasPrefix($0) }) {
                add("masquerade", "Маскируется под системный процесс",
                    "Системная утилита Apple запущена под именем «\(r.name)» из \(r.path) — настоящий компонент macOS лежит в системных папках.", 4)
            }
            return Cached(base: a, noCertificate: false, complete: true)
        }

        // Статическая подпись файла — с кэшем по пути, новые пути в пределах бюджета.
        var signing: SigningInfo??
        var complete = true
        if r.path.isEmpty {
            a.signer = "Файл удалён — проверить нельзя"
        } else if let cached = signingCache[r.path] {
            signing = .some(cached)
        } else if budget > 0, fm.fileExists(atPath: r.path) {
            budget -= 1
            let s = DetailsLoader.signing(r.path)
            signingCache[r.path] = s
            signing = .some(s)
        } else if fm.fileExists(atPath: r.path) {
            complete = false
        }

        var noCertificate = false
        if let signing {
            if let s = signing {
                if s.unsigned {
                    a.signer = "Нет подписи"
                    noCertificate = true
                    add("unsigned", "Нет цифровой подписи", "Файл не подписан — неизвестно, кто его выпустил и не изменён ли он.", 3)
                } else if s.isAdhoc {
                    a.signer = "Ad-hoc (без сертификата)"
                    noCertificate = true
                    add("adhoc", "Подпись без сертификата",
                        "Ad-hoc подпись не указывает разработчика. Нормально для самосборных программ и Homebrew, но так же подписывают и вредоносы.", 1)
                } else if s.isApple {
                    a.signer = "Apple"
                } else {
                    a.signer = Self.vendorName(s)
                }
            } else {
                a.signer = "Не удалось проверить"
            }
        }

        checkLocation(r, noCertificate: noCertificate, add: add)
        checkMasquerade(r, signing: signing ?? nil, add: add)

        if noCertificate, isQuarantined(r.path) {
            add("quarantine", "Скачан из интернета без сертификата",
                "У файла есть карантинная метка загрузки, но нет подписи разработчика — Gatekeeper такие файлы обычно блокирует.", 2)
        }
        if r.uid == myUID, hasDylibInjection(r) {
            add("inject", "Внедрение библиотек (DYLD_INSERT_LIBRARIES)",
                "В окружении процесса задана подгрузка сторонних библиотек — классический способ перехвата чужой программы.", 4)
        }
        if let job = jobsByTarget[r.path] ?? PathTools.outermostApp(r.path).flatMap({ jobsByTarget[$0] }) {
            let risky = noCertificate || job.isScript || job.signing?.unsigned == true || job.signing?.isAdhoc == true
            if risky {
                add("persistence", "Закреплён в автозагрузке",
                    "Запускается автоматически через «\(job.label)» (\(job.scope.title.lowercased())), при этом без подписи разработчика.", 2)
            }
        }
        return Cached(base: a, noCertificate: noCertificate, complete: complete)
    }

    // MARK: Правила

    private static let riskyParents: Set<String> = [
        "Microsoft Word", "Microsoft Excel", "Microsoft PowerPoint", "Microsoft Outlook", "Pages", "Numbers",
        "Keynote", "Preview", "Mail", "Messages", "Safari", "Google Chrome", "Firefox", "Opera", "Brave Browser",
        "Microsoft Edge", "Arc", "Telegram", "WhatsApp", "Slack", "Discord", "Adobe Acrobat Reader", "Adobe Acrobat",
        "zoom.us", "Skype",
    ]
    private static let shellLike: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "tcsh", "csh", "python", "python3", "perl", "ruby", "osascript",
        "curl", "wget", "nc", "ncat", "base64", "openssl", "launchctl", "osacompile", "screencapture",
    ]

    private func checkParent(_ r: ProcessRecord, byPID: [pid_t: ProcessRecord], add: (String, String, String, Int) -> Void) {
        let child = (r.path as NSString).lastPathComponent
        guard Self.shellLike.contains(child.isEmpty ? r.name : child),
              let parent = byPID[r.ppid],
              let app = PathTools.outermostApp(parent.path) else { return }
        let appName = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        guard Self.riskyParents.contains(appName) else { return }
        add("parent", "Необычный родитель",
            "«\(appName)» запустил «\(r.name)». Документы и браузеры не должны запускать командную оболочку — так работают вредоносные макросы и эксплойты.", 2)
    }

    private static let hiddenAllowed: Set<String> = [
        ".vscode", ".vscode-insiders", ".cursor", ".nvm", ".cargo", ".rustup", ".local", ".npm", ".bun", ".deno",
        ".pyenv", ".rbenv", ".sdkman", ".docker", ".orbstack", ".gradle", ".m2", ".conda", ".oh-my-zsh", ".gem",
        ".swiftpm", ".build", ".claude", ".codex", ".cache", ".volta", ".asdf", ".jenv", ".dotnet", ".colima",
    ]

    private func checkLocation(_ r: ProcessRecord, noCertificate: Bool, add: (String, String, String, Int) -> Void) {
        let p = r.path
        guard !p.isEmpty else { return }
        let suspicious: [(String, String)] = [
            ("/tmp/", "временной папки"), ("/private/tmp/", "временной папки"), ("/var/tmp/", "временной папки"),
            ("/private/var/tmp/", "временной папки"), ("/Users/Shared/", "общей папки /Users/Shared"),
            (home + "/Downloads/", "папки «Загрузки»"), (home + "/.Trash/", "Корзины"),
            ("/private/var/folders/", "временной папки приложения"),
        ]
        if let hit = suspicious.first(where: { p.hasPrefix($0.0) }) {
            // Временные папки приложений (/var/folders) используют и легальные установщики — штрафуем мягче.
            let weight = hit.0 == "/private/var/folders/" ? (noCertificate ? 2 : 0) : 3
            if weight > 0 {
                add("location", "Запущен из \(hit.1)",
                    "Обычные программы не работают из \(hit.1); туда часто распаковываются вредоносы.", weight)
            }
            return
        }
        if p.hasPrefix("/Volumes/") {
            add("volume", "Запущен с внешнего диска или образа",
                "Программа работает прямо с подключённого тома (DMG, флешка), а не из «Программ».", 1)
        }
        if noCertificate, p.hasPrefix(home + "/") {
            let components = p.dropFirst(home.count + 1).split(separator: "/").dropLast()
            if let hidden = components.first(where: { $0.hasPrefix(".") && !Self.hiddenAllowed.contains(String($0)) }) {
                add("hidden", "Спрятан в скрытой папке",
                    "Файл без сертификата лежит в скрытой папке «\(hidden)» — так прячут программы от пользователя.", 2)
            }
        }
    }

    private static let systemDirs = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/Applications/",
                                     "/Library/Developer/", "/private/var/db/", "/Library/Application Support/Apple/"]

    private static let systemNames: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer", "mds",
        "mds_stores", "mdworker", "mdworker_shared", "syslogd", "cfprefsd", "trustd", "securityd", "coreaudiod",
        "bluetoothd", "sshd", "cron", "opendirectoryd", "distnoted", "notifyd", "configd", "softwareupdated",
        "XProtect", "XProtectService", "MRT", "kextd", "kernelmanagerd", "logd", "UserEventAgent", "sharingd",
        "airportd", "locationd", "powerd", "nsurlsessiond", "Spotlight", "Safari", "AppleSpell",
    ]

    private func checkMasquerade(_ r: ProcessRecord, signing: SigningInfo?, add: (String, String, String, Int) -> Void) {
        guard signing?.isApple != true else { return }
        let name = r.name.trimmingCharacters(in: .whitespaces)
        let looksSystem = Self.systemNames.contains(name) || name.lowercased().hasPrefix("com.apple.")
            || name != r.name // пробелы по краям имени — приём маскировки
        guard looksSystem else { return }
        add("masquerade", "Маскируется под системный процесс",
            "Имя «\(r.name)» совпадает с компонентом macOS, но файл не подписан Apple и лежит в \(r.path).", 4)
    }

    private func isQuarantined(_ path: String) -> Bool {
        if let cached = quarantineCache[path] { return cached }
        let q = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
        quarantineCache[path] = q
        return q
    }

    private func hasDylibInjection(_ r: ProcessRecord) -> Bool {
        let key = "\(r.pid)-\(r.startTime?.timeIntervalSince1970 ?? 0)"
        if let cached = injectionCache[key] { return cached }
        let env = DetailsLoader.procArgs(r.pid)?.env ?? []
        let hit = env.contains { $0.hasPrefix("DYLD_INSERT_LIBRARIES=") }
        injectionCache[key] = hit
        return hit
    }

    /// Раз в минуту: пересканировать автозагрузку. Возвращает true, если пора пересчитать всё.
    private func refreshJobsIfNeeded() -> Bool {
        let now = MachTime.now()
        guard now - lastJobsScan > 60 else { return false }
        lastJobsScan = now
        var map: [String: LaunchJob] = [:]
        for job in StartupScanner.scanJobs() where job.startsAutomatically {
            if let t = job.target { map[t] = job }
        }
        jobsByTarget = map
        return true
    }

    static func vendorName(_ s: SigningInfo) -> String {
        guard let auth = s.authority else { return "Подписан" }
        var name = auth.replacingOccurrences(of: "Developer ID Application: ", with: "")
            .replacingOccurrences(of: "Apple Development: ", with: "")
        if let team = s.teamID { name = name.replacingOccurrences(of: " (\(team))", with: "") }
        return name
    }

    // MARK: Глубокая проверка по запросу (хеши всех файлов — может занять несколько секунд)

    struct DeepVerification: Sendable {
        let valid: Bool
        /// Нотаризован Apple или распространяется через Mac App Store (который проверяет приложения сам).
        let notarized: Bool
        let message: String
    }

    static func deepVerify(path: String) -> DeepVerification {
        let target = PathTools.innermostApp(path) ?? path
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: target) as CFURL, [], &code) == errSecSuccess, let code else {
            return DeepVerification(valid: false, notarized: false, message: "Не удалось открыть файл для проверки")
        }
        var cfError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, [], nil, &cfError)
        guard status == errSecSuccess else {
            let reason = (cfError?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "код \(status)"
            return DeepVerification(valid: false, notarized: false,
                                    message: status == errSecCSUnsigned ? "Файл не подписан" : "Подпись повреждена или файл изменён: \(reason)")
        }
        func satisfies(_ req: String) -> Bool {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(req as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
            return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
        // OID 1.2.840.113635.100.6.1.9 — сертификат Mac App Store; такие приложения не нотаризуют.
        if satisfies("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists") {
            return DeepVerification(valid: true, notarized: true, message: "Подпись цела, приложение из Mac App Store")
        }
        if satisfies("notarized") {
            return DeepVerification(valid: true, notarized: true, message: "Подпись цела, файл нотаризован Apple")
        }
        return DeepVerification(valid: true, notarized: false,
                                message: "Подпись цела, но файл не нотаризован Apple — Gatekeeper предупредил бы о нём при первом запуске")
    }
}

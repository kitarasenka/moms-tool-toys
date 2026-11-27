import Darwin
import Foundation
import Security

enum FileKind: Sendable {
    case file, directory, socket, pipe, device, other

    var symbol: String {
        switch self {
        case .file: "doc"
        case .directory: "folder"
        case .socket: "network"
        case .pipe: "arrow.left.arrow.right"
        case .device: "cable.connector"
        case .other: "square.dashed"
        }
    }

    /// 0 — файлы, 1 — сеть, 2 — прочее.
    var group: Int {
        switch self {
        case .file, .directory, .device: 0
        case .socket: 1
        case .pipe, .other: 2
        }
    }
}

struct OpenFile: Identifiable, Sendable {
    let id: Int
    let fd: String
    let kind: FileKind
    let title: String
    let detail: String
    let path: String?
}

enum ModuleKind: Int, CaseIterable, Sendable {
    case executable, dyld, sharedCache, framework, library, plugin, font, data

    var title: String {
        switch self {
        case .executable: String(localized: "Исполняемый файл")
        case .dyld: String(localized: "Загрузчик dyld")
        case .sharedCache: String(localized: "Общий кэш dyld")
        case .framework: String(localized: "Фреймворки")
        case .library: String(localized: "Библиотеки")
        case .plugin: String(localized: "Плагины и пакеты")
        case .font: String(localized: "Шрифты")
        case .data: String(localized: "Прочие отображённые файлы")
        }
    }

    var symbol: String {
        switch self {
        case .executable: "terminal"
        case .dyld: "gearshape.2"
        case .sharedCache: "square.stack.3d.up"
        case .framework: "shippingbox"
        case .library: "books.vertical"
        case .plugin: "puzzlepiece.extension"
        case .font: "textformat"
        case .data: "doc.text"
        }
    }

    static func classify(_ p: String, executable: String) -> ModuleKind {
        if p == executable { return .executable }
        if p == "/usr/lib/dyld" { return .dyld }
        if p.contains("dyld_shared_cache") { return .sharedCache }
        let ext = (p as NSString).pathExtension.lowercased()
        if ext == "dylib" || ext == "so" { return .library }
        if ["ttf", "otf", "ttc", "dfont"].contains(ext) { return .font }
        // Ресурсы внутри пакетов (.car, .pak, .loctable…) — это данные, а не код.
        let isCode = ext.isEmpty && !p.contains("/Resources/")
        if isCode && p.contains(".framework/") { return .framework }
        if isCode && (p.contains(".bundle/") || p.contains(".plugin/") || p.contains(".appex/") || p.contains(".xpc/")) {
            return .plugin
        }
        return .data
    }
}

struct ModuleEntry: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let kind: ModuleKind

    var title: String {
        if kind == .framework, let r = path.range(of: ".framework/", options: .backwards) {
            let prefix = path[..<r.lowerBound]
            return (String(prefix) as NSString).lastPathComponent + ".framework"
        }
        return (path as NSString).lastPathComponent
    }
}

struct SigningInfo: Sendable {
    var identifier: String?
    var teamID: String?
    var authority: String?
    var isAdhoc = false
    var isApple = false
    var hardenedRuntime = false
    var unsigned = false

    var summary: String {
        if unsigned { return String(localized: "Не подписан") }
        if isApple { return "Apple" }
        if isAdhoc { return String(localized: "Ad-hoc подпись (без сертификата)") }
        return authority ?? String(localized: "Подписан")
    }
}

struct BundleInfo: Sendable {
    let path: String
    let name: String?
    let identifier: String?
    let version: String?
}

struct ProcessDetails: Sendable {
    var arguments: [String] = []
    var argumentsFromPS = false
    var environment: [String] = []
    var cwd: String?
    var files: [OpenFile] = []
    var filesAvailable = false
    var modules: [ModuleEntry] = []
    var modulesAvailable = false
    var signing: SigningInfo?
    var bundle: BundleInfo?
    var executableSize: UInt64?
    var executableModified: Date?
    var responsiblePID: pid_t?
    var viaAdmin = false
}

enum DetailsLoader {
    static func load(pid: pid_t, path: String) -> ProcessDetails {
        var d = ProcessDetails()

        if let parsed = procArgs(pid) {
            d.arguments = parsed.args
            d.environment = parsed.env
        } else if let cmd = PSReader.commandLine(pid) {
            d.arguments = [cmd]
            d.argumentsFromPS = true
        }

        d.cwd = workingDirectory(pid)

        if let files = openFiles(pid) {
            d.files = files
            d.filesAvailable = true
        }
        if let mods = mappedModules(pid, executable: path) {
            d.modules = mods
            d.modulesAvailable = true
        }

        if !path.isEmpty {
            d.signing = signing(path)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                d.executableSize = (attrs[.size] as? NSNumber)?.uint64Value
                d.executableModified = attrs[.modificationDate] as? Date
            }
            if let app = PathTools.innermostApp(path), let b = Bundle(path: app) {
                let info = b.infoDictionary ?? [:]
                d.bundle = BundleInfo(
                    path: app,
                    name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
                    identifier: b.bundleIdentifier,
                    version: [info["CFBundleShortVersionString"] as? String, (info["CFBundleVersion"] as? String).map { "(\($0))" }]
                        .compactMap { $0 }.joined(separator: " ")
                )
            }
        }

        if let fn = responsibleFn {
            let r = fn(pid)
            if r > 0 { d.responsiblePID = r }
        }
        return d
    }

    // MARK: Аргументы и окружение

    static func procArgs(_ pid: pid_t) -> (args: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }

        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 } // путь исполняемого файла
        while i < size, buf[i] == 0 { i += 1 } // выравнивание

        var strings: [String] = []
        var start = i
        while i < size {
            if buf[i] == 0 {
                strings.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        let args = Array(strings.prefix(argc))
        var env: [String] = []
        for s in strings.dropFirst(argc) {
            if s.isEmpty { break }
            env.append(s)
        }
        return (args, env)
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let p = cString(tuple: info.pvi_cdir.vip_path)
        return p.isEmpty ? nil : p
    }

    // MARK: Открытые файлы и сокеты

    static func openFiles(_ pid: pid_t) -> [OpenFile]? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = Int(bytes) / stride + 32
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity * stride))
        guard got > 0 else { return nil }

        var result: [OpenFile] = []
        for (idx, fd) in fds.prefix(Int(got) / stride).enumerated() {
            let fdNum = fd.proc_fd
            let fdLabel = String(fdNum)
            switch Int32(fd.proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                var vi = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fdNum, PROC_PIDFDVNODEPATHINFO, &vi, size) > 0 else { continue }
                let path = cString(tuple: vi.pvip.vip_path)
                let mode = vi.pvip.vip_vi.vi_stat.vst_mode & S_IFMT
                let kind: FileKind = mode == S_IFDIR ? .directory : (mode == S_IFCHR || mode == S_IFBLK ? .device : .file)
                result.append(OpenFile(id: idx, fd: fdLabel, kind: kind,
                                       title: path.isEmpty ? String(localized: "(без имени)") : (path as NSString).lastPathComponent,
                                       detail: path, path: path.isEmpty ? nil : path))
            case PROX_FDTYPE_SOCKET:
                var si = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                if proc_pidfdinfo(pid, fdNum, PROC_PIDFDSOCKETINFO, &si, size) > 0 {
                    let (title, detail) = describe(socket: si)
                    result.append(OpenFile(id: idx, fd: fdLabel, kind: .socket, title: title, detail: detail, path: nil))
                } else {
                    result.append(OpenFile(id: idx, fd: fdLabel, kind: .socket, title: String(localized: "Сокет"), detail: "", path: nil))
                }
            case PROX_FDTYPE_PIPE:
                result.append(OpenFile(id: idx, fd: fdLabel, kind: .pipe, title: String(localized: "Канал (pipe)"), detail: "", path: nil))
            case PROX_FDTYPE_KQUEUE:
                result.append(OpenFile(id: idx, fd: fdLabel, kind: .other, title: "kqueue", detail: String(localized: "Очередь событий ядра"), path: nil))
            case PROX_FDTYPE_PSHM:
                result.append(OpenFile(id: idx, fd: fdLabel, kind: .other, title: String(localized: "Общая память POSIX"), detail: "", path: nil))
            case PROX_FDTYPE_PSEM:
                result.append(OpenFile(id: idx, fd: fdLabel, kind: .other, title: String(localized: "Семафор POSIX"), detail: "", path: nil))
            default:
                result.append(OpenFile(id: idx, fd: fdLabel, kind: .other, title: String(localized: "Дескриптор"), detail: String(localized: "тип \(fd.proc_fdtype)"), path: nil))
            }
        }
        return result
    }

    private static let tcpStates = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED",
                                    "CLOSE_WAIT", "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"]

    private static func describe(socket si: socket_fdinfo) -> (String, String) {
        let psi = si.psi
        switch psi.soi_kind {
        case 2: // SOCKINFO_TCP
            let tcp = psi.soi_proto.pri_tcp
            let ini = tcp.tcpsi_ini
            let state = Int(tcp.tcpsi_state)
            let stateName = tcpStates.indices.contains(state) ? tcpStates[state] : "?"
            let local = endpoint(ini, local: true)
            let title = state == 1 ? "TCP \(local)" : "TCP \(local) → \(endpoint(ini, local: false))"
            return (title, stateName)
        case 1: // SOCKINFO_IN
            let ini = psi.soi_proto.pri_in
            let proto = psi.soi_protocol == IPPROTO_UDP ? "UDP" : "IP"
            var title = "\(proto) \(endpoint(ini, local: true))"
            if ini.insi_fport != 0 { title += " → \(endpoint(ini, local: false))" }
            return (title, proto == "UDP" ? String(localized: "Датаграммы") : "")
        case 3: // SOCKINFO_UN
            let un = psi.soi_proto.pri_un
            var path = cString(tuple: un.unsi_addr.ua_sun.sun_path)
            if path.isEmpty { path = cString(tuple: un.unsi_caddr.ua_sun.sun_path) }
            return (path.isEmpty ? String(localized: "Unix-сокет") : path, String(localized: "Локальный Unix-сокет"))
        case 5: // SOCKINFO_KERN_CTL
            return (String(localized: "Управляющий сокет ядра"), "kern_ctl")
        case 4: // SOCKINFO_KERN_EVENT
            return (String(localized: "События ядра"), "kern_event")
        case 6: // SOCKINFO_NDRV
            return (String(localized: "Сетевой драйвер"), "ndrv")
        default:
            return (String(localized: "Сокет"), String(localized: "семейство \(psi.soi_family)"))
        }
    }

    private static func endpoint(_ ini: in_sockinfo, local: Bool) -> String {
        let rawPort = local ? ini.insi_lport : ini.insi_fport
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: rawPort))
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var host: String
        if Int32(ini.insi_vflag) & Int32(INI_IPV4) != 0 {
            var a = local ? ini.insi_laddr.ina_46.i46a_addr4 : ini.insi_faddr.ina_46.i46a_addr4
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
            host = cString(buf)
            if host == "0.0.0.0" { host = "*" }
        } else {
            var a = local ? ini.insi_laddr.ina_6 : ini.insi_faddr.ina_6
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
            let s = cString(buf)
            host = s == "::" ? "*" : "[\(s)]"
        }
        return "\(host):\(port == 0 ? "*" : String(port))"
    }

    // MARK: Загруженные модули (отображённые в память файлы)

    /// PROC_PIDREGIONPATHINFO2 из приватной части xnu/proc_info.h: перебирает только регионы,
    /// за которыми стоит файл (на порядок быстрее, чем обход всех регионов).
    private static let regionPathInfoOnlyFiles: Int32 = 22

    static func mappedModules(_ pid: pid_t, executable: String) -> [ModuleEntry]? {
        if let fast = mappedModules(pid, executable: executable, flavor: regionPathInfoOnlyFiles) { return fast }
        return mappedModules(pid, executable: executable, flavor: PROC_PIDREGIONPATHINFO)
    }

    private static func mappedModules(_ pid: pid_t, executable: String, flavor: Int32) -> [ModuleEntry]? {
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var address: UInt64 = 0
        var seen = Set<String>()
        var result: [ModuleEntry] = []
        var iterations = 0

        while iterations < 200_000 {
            iterations += 1
            let r = proc_pidinfo(pid, flavor, address, &info, size)
            if r <= 0 {
                if iterations == 1 { return nil }
                break
            }
            let path = cString(tuple: info.prp_vip.vip_path)
            if !path.isEmpty, seen.insert(path).inserted {
                result.append(ModuleEntry(path: path, kind: ModuleKind.classify(path, executable: executable)))
            }
            let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
            if next <= address { break }
            address = next
        }
        return result.sorted {
            $0.kind.rawValue != $1.kind.rawValue ? $0.kind.rawValue < $1.kind.rawValue
                : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    // MARK: Подпись кода

    static func signing(_ path: String) -> SigningInfo? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var cfInfo: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &cfInfo)
        guard status == errSecSuccess, let dict = cfInfo as? [String: Any] else { return nil }

        var s = SigningInfo()
        s.identifier = dict[kSecCodeInfoIdentifier as String] as? String
        s.teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        s.isAdhoc = flags & 0x2 != 0            // kSecCodeSignatureAdhoc
        s.hardenedRuntime = flags & 0x10000 != 0 // kSecCodeSignatureRuntime
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            s.authority = SecCertificateCopySubjectSummary(leaf) as String?
            s.isApple = s.authority == "Software Signing" || dict[kSecCodeInfoPlatformIdentifier as String] != nil
        }
        s.unsigned = s.identifier == nil
        return s
    }

    // MARK: Ответственный процесс (приватный API, через dlsym — может отсутствовать)

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    // MARK: Режим администратора: lsof с повышенными правами

    static func loadAsAdmin(pid: pid_t, executable: String) async throws -> (files: [OpenFile], modules: [ModuleEntry], cwd: String?) {
        let out = try await AdminRunner.run("/usr/sbin/lsof -n -P -F ftn -p \(pid) 2>/dev/null || true")
        return parseLsof(out, executable: executable)
    }

    static func parseLsof(_ text: String, executable: String) -> (files: [OpenFile], modules: [ModuleEntry], cwd: String?) {
        var files: [OpenFile] = []
        var modules: [ModuleEntry] = []
        var seen = Set<String>()
        var cwd: String?
        var fd = ""
        var type = ""

        for line in text.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "f": fd = value; type = ""
            case "t": type = value
            case "n":
                switch fd {
                case "cwd": cwd = value
                case "rtd": break
                case "txt":
                    if seen.insert(value).inserted {
                        modules.append(ModuleEntry(path: value, kind: ModuleKind.classify(value, executable: executable)))
                    }
                default:
                    let kind: FileKind
                    switch type {
                    case "REG": kind = .file
                    case "DIR": kind = .directory
                    case "CHR", "BLK": kind = .device
                    case "IPv4", "IPv6", "unix", "systm", "ndrv": kind = .socket
                    case "PIPE", "FIFO": kind = .pipe
                    default: kind = .other
                    }
                    let isPath = value.hasPrefix("/")
                    files.append(OpenFile(id: files.count, fd: fd, kind: kind,
                                          title: isPath && kind != .socket ? (value as NSString).lastPathComponent : value,
                                          detail: isPath && kind != .socket ? value : type,
                                          path: isPath ? value : nil))
                }
            default: break
            }
        }
        modules.sort {
            $0.kind.rawValue != $1.kind.rawValue ? $0.kind.rawValue < $1.kind.rawValue
                : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return (files, modules, cwd)
    }
}

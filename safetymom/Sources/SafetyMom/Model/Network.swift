import Foundation
import SystemConfiguration

// MARK: - Модель

struct ProxyInfo: Sendable, Hashable {
    var kind: String
    var address: String
}

struct DNSServer: Sendable, Hashable, Identifiable {
    var address: String
    var label: String
    var level: Level
    var id: String { address }
}

struct HostsEntry: Sendable, Hashable, Identifiable {
    var ip: String
    var names: [String]
    var level: Level
    var note: String
    var id: String { ip + " " + names.joined(separator: " ") }
}

struct ConfigProfile: Sendable, Hashable, Identifiable {
    var name: String
    var organization: String?
    var installed: String?
    var id: String { name + (organization ?? "") }
}

struct NetworkReport: Sendable {
    var proxies: [ProxyInfo] = []
    var dns: [DNSServer] = []
    var hosts: [HostsEntry] = []
    var hostsReadable = true
    var profiles: [ConfigProfile] = []
    var profilesChecked = true
    var mdm: Bool?

    var proxyLevel: Level { proxies.isEmpty ? .ok : .warn }
    var dnsLevel: Level { dns.isEmpty ? .unknown : (dns.map(\.level).max() ?? .ok) }
    var hostsLevel: Level { hostsReadable ? (hosts.map(\.level).max() ?? .ok) : .unknown }
    var profilesLevel: Level { !profilesChecked ? .unknown : (profiles.isEmpty && mdm != true ? .ok : .warn) }
}

// MARK: - Сбор

enum NetworkScanner {
    static func scan() -> NetworkReport {
        var r = NetworkReport()
        if let d = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] { r.proxies = proxies(d) }
        r.dns = dnsAddresses().map(classifyDNS)
        if let text = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) {
            r.hosts = hosts(text)
        } else {
            r.hostsReadable = false
        }
        let sp = Shell.run("/usr/sbin/system_profiler", ["SPConfigurationProfileDataType", "-json"], timeout: 20)
        if sp.ok, let data = sp.output.data(using: .utf8) {
            r.profiles = profiles(json: data)
        } else {
            r.profilesChecked = false
        }
        let st = Shell.run("/usr/bin/profiles", ["status", "-type", "enrollment"], timeout: 8)
        if st.ok { r.mdm = mdmEnrolled(st.output) }
        return r
    }

    // MARK: Прокси

    static func proxies(_ d: [String: Any]) -> [ProxyInfo] {
        func on(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }
        func addr(_ h: String, _ p: String) -> String {
            let host = d[h] as? String ?? "?"
            return (d[p] as? NSNumber).map { "\(host):\($0)" } ?? host
        }
        var out: [ProxyInfo] = []
        if on("HTTPEnable") { out.append(.init(kind: "Веб-прокси (HTTP)", address: addr("HTTPProxy", "HTTPPort"))) }
        if on("HTTPSEnable") { out.append(.init(kind: "Защищённый веб-прокси (HTTPS)", address: addr("HTTPSProxy", "HTTPSPort"))) }
        if on("SOCKSEnable") { out.append(.init(kind: "SOCKS-прокси", address: addr("SOCKSProxy", "SOCKSPort"))) }
        if on("ProxyAutoConfigEnable") {
            out.append(.init(kind: "Автонастройка прокси (PAC)", address: d["ProxyAutoConfigURLString"] as? String ?? "?"))
        }
        return out
    }

    // MARK: DNS

    static func dnsAddresses() -> [String] {
        if let store = SCDynamicStoreCreate(nil, "SafetyMom" as CFString, nil, nil),
           let v = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
           let list = v["ServerAddresses"] as? [String], !list.isEmpty {
            return list
        }
        return scutilDNS(Shell.run("/usr/sbin/scutil", ["--dns"]).output)
    }

    /// Запасной путь: адреса из `scutil --dns` («nameserver[0] : 192.168.1.1»), без повторов.
    static func scutilDNS(_ out: String) -> [String] {
        var seen: [String] = []
        for line in out.split(separator: "\n") where line.contains("nameserver[") {
            if let v = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !seen.contains(v) {
                seen.append(v)
            }
        }
        return seen
    }

    static let publicDNS: [String: String] = [
        "1.1.1.1": "Cloudflare", "1.0.0.1": "Cloudflare", "2606:4700:4700::1111": "Cloudflare", "2606:4700:4700::1001": "Cloudflare",
        "8.8.8.8": "Google", "8.8.4.4": "Google", "2001:4860:4860::8888": "Google", "2001:4860:4860::8844": "Google",
        "9.9.9.9": "Quad9", "149.112.112.112": "Quad9", "208.67.222.222": "OpenDNS", "208.67.220.220": "OpenDNS",
        "77.88.8.8": "Яндекс DNS", "77.88.8.1": "Яндекс DNS", "77.88.8.88": "Яндекс DNS (безопасный)",
        "77.88.8.2": "Яндекс DNS (безопасный)", "77.88.8.7": "Яндекс DNS (семейный)", "77.88.8.3": "Яндекс DNS (семейный)",
        "94.140.14.14": "AdGuard DNS", "94.140.15.15": "AdGuard DNS", "185.228.168.9": "CleanBrowsing",
        "100.100.100.100": "Tailscale (VPN)",
    ]

    static func classifyDNS(_ a: String) -> DNSServer {
        if let name = publicDNS[a] { return DNSServer(address: a, label: "\(name) — известный надёжный сервис", level: .ok) }
        if a.hasPrefix("127.") || a == "::1" {
            return DNSServer(address: a, label: "Программа на этом Mac (VPN или блокировщик рекламы). Если вы такого не ставили — это подозрительно.", level: .warn)
        }
        if isPrivate(a) { return DNSServer(address: a, label: "Ваш роутер или локальная сеть — так и должно быть", level: .ok) }
        return DNSServer(address: a, label: "Незнакомый сервер. Это может быть DNS провайдера или VPN — тогда всё нормально. Если нет — его могла подставить вредоносная программа.", level: .warn)
    }

    static func isPrivate(_ a: String) -> Bool {
        let low = a.lowercased()
        if low.hasPrefix("fe80:") || low.hasPrefix("fd") || low.hasPrefix("fc") { return true }
        let p = a.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
            || (p[0] == 100 && (64...127).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }

    // MARK: hosts

    static let defaultHosts: Set<String> = ["localhost", "broadcasthost", "localhost.localdomain"]
    static let blockIPs: Set<String> = ["0.0.0.0", "127.0.0.1", "::1", "::", "0:0:0:0:0:0:0:0"]
    static let securityDomains = ["apple.com", "icloud.com", "mzstatic.com", "microsoft.com", "google.com", "kaspersky", "eset",
                                  "avast", "avg.com", "malwarebytes", "drweb", "norton", "bitdefender", "virustotal", "update"]
    static let importantDomains = ["google", "yandex", "ya.ru", "vk.com", "mail.ru", "sber", "tinkoff", "tbank", "gosuslugi",
                                   "apple.com", "icloud", "paypal", "facebook", "instagram", "ozon", "wildberries", "alfabank",
                                   "vtb", "bank", "gmail", "whatsapp", "telegram", "microsoft", "live.com", "outlook"]

    static func hosts(_ text: String) -> [HostsEntry] {
        var out: [HostsEntry] = []
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let ip = parts[0], names = Array(parts.dropFirst()).map { $0.lowercased() }
            if names.allSatisfy({ defaultHosts.contains($0) }) { continue }
            out.append(classifyHosts(ip: ip, names: names))
        }
        return out
    }

    static func classifyHosts(ip: String, names: [String]) -> HostsEntry {
        let blocked = blockIPs.contains(ip) || ip.lowercased().hasPrefix("fe80::1%lo")
        if blocked {
            if names.contains(where: { n in securityDomains.contains { n.contains($0) } }) {
                return HostsEntry(ip: ip, names: names, level: .warn,
                                  note: "Закрыт доступ к сайту обновлений или антивируса. Так делают вредоносные программы, чтобы Mac не получал защиту.")
            }
            return HostsEntry(ip: ip, names: names, level: .ok, note: "Сайт заблокирован — обычно это делает блокировщик рекламы. Не опасно.")
        }
        if names.contains(where: { n in importantDomains.contains { n.contains($0) } }) {
            return HostsEntry(ip: ip, names: names, level: .danger,
                              note: "Известный сайт направлен на чужой адрес — вместо настоящего сайта может открываться поддельный (например, банк).")
        }
        return HostsEntry(ip: ip, names: names, level: .warn,
                          note: "Сайт направлен на другой адрес. Так делают разработчики и некоторые программы; если вы не знаете, откуда эта строка, — покажите её знакомому специалисту.")
    }

    // MARK: Профили

    static func profiles(json data: Data) -> [ConfigProfile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let top = root["SPConfigurationProfileDataType"] as? [[String: Any]] else { return [] }
        var out: [ConfigProfile] = []
        func isProfile(_ d: [String: Any]) -> Bool {
            d.keys.contains { $0.contains("profile_identifier") || $0.contains("organization") || $0.contains("install_date") || $0.contains("verification_state") }
        }
        func value(_ d: [String: Any], _ part: String) -> String? {
            d.first { $0.key.contains(part) }.flatMap { $0.value as? String }
        }
        func walk(_ items: [[String: Any]]) {
            for d in items {
                if isProfile(d), let name = d["_name"] as? String {
                    out.append(ConfigProfile(name: name, organization: value(d, "organization"), installed: value(d, "install_date")))
                } else if let sub = d["_items"] as? [[String: Any]] {
                    walk(sub)
                }
            }
        }
        walk(top)
        if out.isEmpty {   // незнакомая структура — берём имена первого уровня вложенности
            for g in top { for d in g["_items"] as? [[String: Any]] ?? [] { if let n = d["_name"] as? String { out.append(ConfigProfile(name: n)) } } }
        }
        return out
    }

    static func mdmEnrolled(_ out: String) -> Bool? {
        for line in out.split(separator: "\n") where line.lowercased().contains("mdm enrollment") {
            return line.lowercased().contains("yes")
        }
        return nil
    }
}

import SwiftUI

struct NetworkView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let n = state.network {
                ScrollView {
                    VStack(spacing: 12) {
                        ProxyCard(n: n)
                        DNSCard(n: n)
                        HostsCard(n: n)
                        ProfilesCard(n: n)
                        StartupCard()
                    }
                    .padding(16)
                }
                .fillAvailable()
            } else {
                LoadingView(text: "Проверяю прокси, DNS и профили…")
            }
        }
        .navigationTitle("Сеть и профили")
        .task { if state.network == nil { await state.loadNetwork() } }
        .toolbar {
            ToolbarItem {
                Button { Task { await state.loadNetwork() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .disabled(state.networkLoading)
            }
        }
    }
}

private struct Explain: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProxyCard: View {
    let n: NetworkReport

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "arrow.triangle.branch", title: "Прокси", level: n.proxyLevel,
                              status: n.proxies.isEmpty ? "Не используется" : "Включён")
                if n.proxies.isEmpty {
                    Explain(text: "Сайты открываются напрямую, без посредника.")
                } else {
                    ForEach(n.proxies, id: \.self) { p in
                        HStack { Text(p.kind); Spacer(); Text(p.address).font(.body.monospaced()).textSelection(.enabled) }
                            .font(.callout)
                    }
                    Explain(text: "Весь интернет идёт через этот адрес. Так работают некоторые VPN и рабочие сети. Если вы ничего такого не ставили — это частый признак рекламной или вредоносной программы: она подсовывает рекламу и может подменять сайты.")
                    Button(SettingsLink.network.title) { Settings.open(.network) }.controlSize(.small)
                }
            }
        }
    }
}

private struct DNSCard: View {
    let n: NetworkReport

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "signpost.right.and.left", title: "DNS", level: n.dnsLevel,
                              status: n.dns.isEmpty ? "Нет сети" : (n.dnsLevel == .ok ? "В порядке" : "Проверьте"))
                Explain(text: "DNS — «справочная» интернета: по имени сайта выдаёт его адрес. Если её подменить, вместо настоящего банка может открыться подделка.")
                ForEach(n.dns) { d in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: d.level.symbol).foregroundStyle(d.level.color).frame(width: 18)
                        Text(d.address).font(.body.monospaced()).textSelection(.enabled).frame(minWidth: 130, alignment: .leading)
                        Text(d.label).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if n.dnsLevel == .warn {
                    Button(SettingsLink.network.title) { Settings.open(.network) }.controlSize(.small)
                }
            }
        }
    }
}

private struct HostsCard: View {
    let n: NetworkReport

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "doc.text.magnifyingglass", title: "Файл hosts", level: n.hostsLevel,
                              status: !n.hostsReadable ? "Не прочитать" : (n.hosts.isEmpty ? "Стандартный" : Fmt.count(n.hosts.count, "строка", "строки", "строк")))
                Explain(text: n.hosts.isEmpty
                        ? "В /etc/hosts только стандартные строки — никакой сайт не перенаправлен."
                        : "Файл /etc/hosts может направить сайт на любой адрес в обход DNS. Вот что в нём нестандартного:")
                ForEach(n.hosts) { h in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: h.level.symbol).foregroundStyle(h.level.color).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(h.names.joined(separator: " ")) → \(h.ip)").font(.callout.monospaced()).textSelection(.enabled)
                            Text(h.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if n.hostsLevel >= .warn {
                    Explain(text: "Исправить файл можно только с паролем администратора — попросите знакомого специалиста убрать лишние строки.")
                }
            }
        }
    }
}

private struct ProfilesCard: View {
    let n: NetworkReport

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "person.badge.shield.checkmark", title: "Профили конфигурации", level: n.profilesLevel,
                              status: !n.profilesChecked ? "Не удалось" : (n.profiles.isEmpty ? "Нет" : Fmt.count(n.profiles.count, "профиль", "профиля", "профилей")))
                if n.mdm == true {
                    Explain(text: "Mac подключён к системе управления организации (MDM). Для рабочего компьютера это нормально; для домашнего — нет.")
                }
                if n.profiles.isEmpty {
                    Explain(text: "Профилей нет — никто не менял настройки Mac в обход вас.")
                } else {
                    ForEach(n.profiles) { p in
                        HStack(alignment: .firstTextBaseline) {
                            Text(p.name).font(.callout.weight(.medium))
                            if let o = p.organization { Text(o).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if let d = p.installed { Text(d).font(.caption).foregroundStyle(.tertiary) }
                        }
                    }
                    Explain(text: "Профиль может включать прокси, ставить сертификаты и запрещать менять настройки. На рабочем Mac их ставит организация. Если это домашний Mac и вы не знаете, откуда профиль, — удалите его в Системных настройках.")
                }
                if !n.profiles.isEmpty || n.mdm == true {
                    Button(SettingsLink.profiles.title) { Settings.open(.profiles) }.controlSize(.small)
                }
            }
        }
    }
}

private struct StartupCard: View {
    @Environment(AppState.self) private var state
    private let perfID = "local.perfmon.app"

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                LevelIcon(icon: "power", level: .unknown, size: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Что запускается само").font(.headline)
                    Explain(text: "Рекламные программы часто прячутся в автозагрузке. Её подробно показывает PerfMom — там же можно выключить лишнее и проверить подозрительные процессы.")
                    if state.demo || Apps.url(perfID) != nil {
                        Button("Открыть автозагрузку в PerfMom") { if !state.demo { Apps.open(perfID, arguments: ["--section", "startup"]) } }
                            .controlSize(.small)
                    } else {
                        Text("PerfMom не установлен — поставьте его вместе с остальными инструментами Mom's Tool Toys.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

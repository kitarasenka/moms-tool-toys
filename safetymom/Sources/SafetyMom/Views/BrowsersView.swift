import SwiftUI

private struct PendingBlock: Identifiable {
    var report: BrowserReport
    var sites: [SiteNotification]
    var id: String { report.id + sites.map(\.id).joined() }
}

struct BrowsersView: View {
    @Environment(AppState.self) private var state
    @State private var pending: PendingBlock?

    var body: some View {
        @Bindable var state = state
        Group {
            if !state.browsersLoaded {
                LoadingView(text: "Смотрю браузеры: расширения и уведомления от сайтов…")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        Picker("", selection: $state.browserTab) {
                            ForEach(BrowserTab.allCases, id: \.self) { t in Text(tabTitle(t)).tag(t) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 460)

                        if let m = state.message {
                            MessageBar(text: m, isError: state.messageIsError) { state.message = nil }
                        }
                        FullDiskAccessBanner(reason: "Без него не видно, каким сайтам разрешены уведомления в Safari.")
                        if state.browsers.isEmpty {
                            Text("Браузеров не найдено.").foregroundStyle(.secondary)
                        }
                        if state.browserTab == .notifications {
                            ScamExplainer()
                            ForEach(state.browsers) { r in NotificationsCard(report: r) { pending = PendingBlock(report: r, sites: $0) } }
                        } else {
                            Text("SafetyMom ничего не удаляет сам. Лишнее расширение удалите на странице расширений браузера — кнопка у каждого браузера. Не помните, что это и зачем, — удаляйте смело: нужное потом можно поставить снова.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(state.browsers) { r in ExtensionsCard(report: r) }
                        }
                    }
                    .padding(16)
                }
                .fillAvailable()
            }
        }
        .navigationTitle("Браузеры")
        .task { if !state.browsersLoaded { await state.loadBrowsers() } }
        .toolbar {
            ToolbarItem {
                Button { Task { await state.loadBrowsers() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .help("Перечитать браузеры")
                    .disabled(state.browsersLoading)
            }
        }
        .alert(pending.map { "Запретить уведомления в \($0.report.def.name)?" } ?? "",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { p in
            Button("Запретить", role: .destructive) { Task { await state.block(p.sites, in: p.report) } }
            Button("Отменить", role: .cancel) {}
        } message: { p in
            Text(p.sites.count == 1
                 ? "Сайт \(p.sites[0].host) больше не сможет присылать уведомления. Сам сайт открываться будет как обычно."
                 : "\(Fmt.count(p.sites.count, "сайт", "сайта", "сайтов")) больше не смогут присылать уведомления: \(p.sites.prefix(5).map(\.host).joined(separator: ", "))\(p.sites.count > 5 ? "…" : ""). Сами сайты открываться будут как обычно.")
            + Text("\n\nКопия прежних настроек браузера сохранится в папке SafetyMom.")
        }
    }

    private func tabTitle(_ t: BrowserTab) -> String {
        let n = t == .notifications ? state.browsers.reduce(0) { $0 + $1.notifications.count }
                                    : state.browsers.reduce(0) { $0 + $1.extensions.count }
        return "\(t.title) (\(n))"
    }
}

/// Главный сценарий: «Ваш Mac заражён!» во всплывающем окне.
private struct ScamExplainer: View {
    var body: some View {
        Card(tint: Brand.blue) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.bubble.fill").font(.system(size: 26)).foregroundStyle(Brand.gradient)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Выскакивает «Ваш Mac заражён!» или «Вы выиграли»?").font(.headline)
                    Text("Это не macOS и не антивирус, а уведомления от сайта, которому когда-то нажали «Разрешить». Самого вируса нет. Запретите такому сайту уведомления — и сообщения прекратятся. Ничего не скачивайте, не платите и не звоните по номерам из таких окон.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct BrowserHeader<Actions: View>: View {
    let report: BrowserReport
    let level: Level
    let status: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleID: report.def.bundleID, fallback: "safari", size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(report.def.name).font(.headline)
                    if report.running {
                        Text("запущен").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.gray.opacity(0.15), in: Capsule())
                    }
                }
                if report.profiles.count > 1 {
                    Text(Fmt.count(report.profiles.count, "профиль", "профиля", "профилей")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            actions
            LevelBadge(text: status, level: level)
        }
    }
}

private struct NotificationsCard: View {
    @Environment(AppState.self) private var state
    let report: BrowserReport
    let onBlock: ([SiteNotification]) -> Void

    var body: some View {
        let list = report.notifications
        let suspicious = list.filter { $0.level != .ok }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                BrowserHeader(report: report, level: report.worstNotification, status: status(list)) {
                    if report.def.notificationsPage != nil || report.def.engine.isSafari {
                        Button("Настройки уведомлений") { state.openNotificationSettings(report) }.controlSize(.small)
                    }
                }
                if report.canRevoke && report.running && !suspicious.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("Чтобы запретить уведомления, закройте \(report.def.name) — он помнит настройки и перезапишет их при выходе. Вкладки откроются снова.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Закрыть \(report.def.name)") { state.quit(report) }.controlSize(.small)
                    }
                    .padding(8)
                    .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if !report.notificationsReadable {
                    Text("Список не прочитать без полного доступа к диску.").font(.callout).foregroundStyle(.secondary)
                } else if list.isEmpty {
                    Text("Ни одному сайту не разрешено присылать уведомления.").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { Divider() }
                            SiteRow(site: s, report: report) { onBlock([s]) }
                        }
                    }
                }
                if report.canRevoke && suspicious.count > 1 {
                    HStack {
                        Spacer()
                        Button("Запретить все незнакомые (\(suspicious.count))") { onBlock(suspicious) }
                            .buttonStyle(GlowCapsuleStyle())
                            .disabled(report.running && !state.demo)
                    }
                }
                if let note = report.notificationsNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func status(_ list: [SiteNotification]) -> String {
        if !report.notificationsReadable { return "Не проверить" }
        if list.isEmpty { return "Нет разрешений" }
        let bad = list.filter { $0.level == .danger }.count
        if bad > 0 { return "Похоже на спам: \(bad)" }
        return Fmt.count(list.count, "сайт", "сайта", "сайтов")
    }
}

private struct SiteRow: View {
    @Environment(AppState.self) private var state
    let site: SiteNotification
    let report: BrowserReport
    let onBlock: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: site.level.symbol).foregroundStyle(site.level.color).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.host).font(.body.weight(.medium))
                Text(site.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(([report.profiles.count > 1 ? "профиль «\(site.profile)»" : nil,
                       site.since.map { "разрешено \(Fmt.date($0))" }] as [String?]).compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if report.canRevoke {
                Button("Запретить") { onBlock() }
                    .controlSize(.small)
                    .disabled(report.running && !state.demo)
                    .help(report.running && !state.demo ? "Сначала закройте \(report.def.name)" : "Сайт больше не сможет присылать уведомления")
            }
        }
        .padding(.vertical, 7)
    }
}

private struct ExtensionsCard: View {
    @Environment(AppState.self) private var state
    let report: BrowserReport

    var body: some View {
        let list = report.extensions
        Card {
            VStack(alignment: .leading, spacing: 10) {
                BrowserHeader(report: report, level: report.worstExtension, status: status(list)) {
                    Button(report.def.engine.isSafari ? "Открыть Safari" : "Страница расширений") { state.openExtensions(report) }
                        .controlSize(.small)
                }
                if list.isEmpty {
                    Text("Расширений нет.").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                            if i > 0 { Divider() }
                            ExtensionRow(ext: e, showProfile: report.profiles.count > 1)
                        }
                    }
                }
                if let note = report.extensionsNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func status(_ list: [BrowserExtension]) -> String {
        let bad = list.filter { $0.level == .danger }.count, warn = list.filter { $0.level == .warn }.count
        if bad > 0 { return "Подозрительных: \(bad)" }
        if warn > 0 { return "Проверьте: \(warn)" }
        return list.isEmpty ? "Нет" : Fmt.count(list.count, "расширение", "расширения", "расширений")
    }
}

private struct ExtensionRow: View {
    let ext: BrowserExtension
    let showProfile: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ext.level.symbol).foregroundStyle(ext.level.color).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ext.name).font(.body.weight(.medium)).lineLimit(1)
                    if !ext.version.isEmpty { Text(ext.version).font(.caption).foregroundStyle(.tertiary) }
                    if !ext.enabled { Chip(text: "выключено") }
                }
                if !ext.flags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(ext.flags, id: \.self) { f in Chip(text: f.title, risky: f.isRisky).help(f.explain) }
                    }
                }
                if ext.level != .ok, let why = ext.flags.first(where: \.isRisky) ?? ext.flags.first {
                    Text(why.explain).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let meta = [showProfile ? "профиль «\(ext.profile)»" : nil, ext.installed.map { "установлено \(Fmt.date($0))" }].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 7)
        .opacity(ext.enabled ? 1 : 0.7)
    }
}

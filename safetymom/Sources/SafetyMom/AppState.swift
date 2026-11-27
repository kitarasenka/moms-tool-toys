import AppKit
import Observation
import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable {
    case checks, browsers, network

    var title: String {
        switch self {
        case .checks: "Проверка"
        case .browsers: "Браузеры"
        case .network: "Сеть и профили"
        }
    }

    var icon: String {
        switch self {
        case .checks: "checkmark.shield"
        case .browsers: "safari"
        case .network: "network"
        }
    }
}

enum BrowserTab: String, Hashable, CaseIterable {
    case notifications, extensions
    var title: String { self == .notifications ? "Уведомления от сайтов" : "Расширения" }
}

@Observable @MainActor
final class AppState {
    let demo: Bool
    var section: SidebarSection = .checks
    var fullDiskAccess = FullDiskAccess.granted

    var checks: [CheckResult] = []
    var checksLoading = false
    var checkedAt: Date?

    var browsers: [BrowserReport] = []
    var browsersLoading = false
    var browsersLoaded = false
    var browserTab: BrowserTab = .notifications
    var message: String?
    var messageIsError = false

    var network: NetworkReport?
    var networkLoading = false

    private var observers: [NSObjectProtocol] = []

    init(demo: Bool) {
        self.demo = demo
        if demo {
            checks = Demo.checks
            checkedAt = .now
            browsers = Demo.browsers
            browsersLoaded = true
            network = Demo.network
            fullDiskAccess = true
        }
        // Браузер закрыли или открыли — кнопки «Запретить» становятся доступны или нет.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunning() }
            })
        }
    }

    var verdict: Verdict { Verdict(checks) }

    func level(of s: SidebarSection) -> Level? {
        switch s {
        case .checks: return checks.isEmpty ? nil : verdict.level
        case .browsers:
            guard browsersLoaded else { return nil }
            return browsers.flatMap { [$0.worstNotification, $0.worstExtension] }.filter { $0 != .unknown }.max() ?? .ok
        case .network:
            guard let n = network else { return nil }
            return [n.proxyLevel, n.dnsLevel, n.hostsLevel, n.profilesLevel].filter { $0 != .unknown }.max() ?? .ok
        }
    }

    // MARK: Загрузка

    func runChecks() async {
        guard !demo, !checksLoading else { return }
        checksLoading = true
        checks = await Task.detached { await SystemChecks.runAll() }.value
        checkedAt = .now
        checksLoading = false
    }

    func loadBrowsers() async {
        guard !demo, !browsersLoading else { return }
        browsersLoading = true
        let fda = fullDiskAccess
        browsers = await Task.detached { BrowserScanner.reports(fullDiskAccess: fda) }.value
        browsersLoading = false
        browsersLoaded = true
    }

    func loadNetwork() async {
        guard !demo, !networkLoading else { return }
        networkLoading = true
        network = await Task.detached { NetworkScanner.scan() }.value
        networkLoading = false
    }

    func refreshAll() {
        Task { await runChecks() }
        Task { await loadBrowsers() }
        Task { await loadNetwork() }
    }

    /// Вернулись в окно: могли дать полный доступ или поменять настройки — перечитываем.
    func didBecomeActive() {
        guard !demo else { return }
        let was = fullDiskAccess
        fullDiskAccess = FullDiskAccess.granted
        if checkedAt.map({ Date.now.timeIntervalSince($0) > 5 }) ?? false { Task { await runChecks() } }
        if fullDiskAccess != was || browsersLoaded { Task { await loadBrowsers() } }
        if network != nil { Task { await loadNetwork() } }
    }

    func refreshRunning() {
        guard !demo else { return }
        for i in browsers.indices { browsers[i].running = Apps.isRunning(browsers[i].def.bundleID) }
    }

    // MARK: Действия

    func quit(_ r: BrowserReport) {
        if demo {
            if let i = browsers.firstIndex(where: { $0.id == r.id }) { browsers[i].running = false }
            return
        }
        Apps.quit(r.def.bundleID)
    }

    func openExtensions(_ r: BrowserReport) {
        guard !demo else { return }
        if let page = r.def.extensionsPage { Apps.open(page, in: r.def.bundleID) } else { Apps.open(r.def.bundleID) }
    }

    func openNotificationSettings(_ r: BrowserReport) {
        guard !demo else { return }
        if let page = r.def.notificationsPage { Apps.open(page, in: r.def.bundleID) } else { Settings.open(.notifications) }
    }

    /// Запретить сайтам уведомления (Chromium; браузер должен быть закрыт).
    func block(_ sites: [SiteNotification], in r: BrowserReport) async {
        guard !sites.isEmpty else { return }
        if demo {
            if let i = browsers.firstIndex(where: { $0.id == r.id }) {
                let ids = Set(sites.map(\.id))
                browsers[i].notifications.removeAll { ids.contains($0.id) }
            }
            show("Готово: \(Fmt.count(sites.count, "сайт больше не сможет", "сайта больше не смогут", "сайтов больше не смогут")) присылать уведомления (в демо — понарошку).")
            return
        }
        let running = Apps.isRunning(r.def.bundleID)
        let groups = Dictionary(grouping: sites.filter { $0.prefs != nil }, by: { $0.prefs! })
        let def = r.def
        let result: Result<URL?, Error> = await Task.detached {
            do {
                var last: URL?
                for (prefs, list) in groups {
                    let label = "\(def.id)-\(prefs.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: " ", with: "_"))"
                    last = try NotificationRevoker.block(keys: list.map(\.key), prefs: prefs, backupDir: Paths.backups, label: label,
                                                         browserRunning: running, browserName: def.name)
                }
                return .success(last)
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let backup):
            show("Готово: \(Fmt.count(sites.count, "сайт больше не сможет", "сайта больше не смогут", "сайтов больше не смогут")) присылать уведомления в \(def.name)."
                 + (backup.map { " Копия прежних настроек — \(Paths.pretty($0.deletingLastPathComponent().path))." } ?? ""))
        case .failure(let e):
            show(e.localizedDescription, error: true)
        }
        await loadBrowsers()
    }

    func show(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }
}

import AppKit
import Observation
import SwiftUI

enum Pane: Int, CaseIterable, Identifiable {
    case report, call, problems
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .report: String(localized: "Отчёт о Mac")
        case .call: String(localized: "Позвать на помощь")
        case .problems: String(localized: "Частые проблемы")
        }
    }

    var icon: String {
        switch self {
        case .report: "doc.text.magnifyingglass"
        case .call: "person.2.wave.2"
        case .problems: "lightbulb"
        }
    }
}

@MainActor
@Observable
final class AppState {
    let demo: Bool
    @ObservationIgnored let store: HelperStore

    var section: Pane = .report
    var report: SystemReport?
    var collecting = false
    var includeSerial = false
    var helpers: [Helper] = []
    var editing: Helper?
    var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(demo: Bool) {
        self.demo = demo
        if demo {
            store = HelperStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent("helpmom-demo-\(UUID().uuidString)"))
            helpers = DemoData.helpers
            report = DemoData.report()
        } else {
            store = HelperStore(dir: HelperStore.defaultDir)
            helpers = store.load()
            refresh()
        }
    }

    var reportText: String { report?.text(includeSerial: includeSerial) ?? "" }

    func refresh() {
        if demo {
            report = DemoData.report()
            show("Отчёт обновлён")
            return
        }
        guard !collecting else { return }
        collecting = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { await Collector.collect() }.value
            report = r
            collecting = false
        }
    }

    func show(_ message: String.LocalizationValue) {
        toast = String(localized: message)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Отчёт

    func copyReport() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(reportText, forType: .string)
        show("Отчёт скопирован — вставьте его в сообщение (⌘V)")
    }

    func saveReportToDesktop() {
        let desk = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let stamp = Date().formatted(.iso8601.year().month().day())
        var url = desk.appendingPathComponent(String(localized: "Отчёт о Mac \(stamp).txt"))
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = desk.appendingPathComponent(String(localized: "Отчёт о Mac \(stamp) (\(n)).txt"))
            n += 1
        }
        do {
            try reportText.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            show("Сохранено на Рабочий стол: \(url.lastPathComponent)")
        } catch {
            show("Не получилось сохранить: \(error.localizedDescription)")
        }
    }

    // MARK: Помощники

    func save(_ h: Helper) {
        if let i = helpers.firstIndex(where: { $0.id == h.id }) { helpers[i] = h } else { helpers.append(h) }
        persist()
    }

    func delete(_ h: Helper) {
        helpers.removeAll { $0.id == h.id }
        persist()
    }

    private func persist() {
        do { try store.save(helpers) } catch { show("Не получилось сохранить список: \(error.localizedDescription)") }
    }

    func faceTime(_ h: Helper, audio: Bool) {
        guard let handle = h.appleHandle, let url = Contact.faceTime(handle, audio: audio) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static let askText = String(localized: "Привет! Можешь помочь с компьютером? Сейчас удобно?")

    /// Сообщения с готовым текстом (NSSharingService подставляет получателя); если не вышло — просто открыть чат.
    func message(_ h: Helper, text: String = AppState.askText) {
        guard let handle = h.appleHandle else { return }
        if let s = NSSharingService(named: .composeMessage) {
            s.recipients = [handle]
            if s.canPerform(withItems: [text]) { s.perform(withItems: [text]); return }
        }
        if let url = Contact.iMessage(handle) { NSWorkspace.shared.open(url) }
    }

    func telegram(_ h: Helper, copying text: String? = nil) {
        guard let user = h.telegramName else { return }
        if let text {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            show("Отчёт скопирован — в Telegram нажмите ⌘V и отправьте")
        }
        if let app = Contact.telegramApp(user), NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else if let web = Contact.telegramWeb(user) {
            NSWorkspace.shared.open(web)
        }
    }

    /// Отправить отчёт: Сообщения → e-mail → Telegram (что есть у помощника).
    func sendReport(to h: Helper) {
        let text = reportText
        if let handle = h.appleHandle, let s = NSSharingService(named: .composeMessage) {
            s.recipients = [handle]
            if s.canPerform(withItems: [text]) { s.perform(withItems: [text]); return }
        }
        if let mail = Contact.email(h.email), let s = NSSharingService(named: .composeEmail) {
            s.recipients = [mail]
            s.subject = String(localized: "Отчёт о моём Mac")
            if s.canPerform(withItems: [text]) { s.perform(withItems: [text]); return }
        }
        if h.telegramName != nil { telegram(h, copying: text); return }
        copyReport()
    }

    // MARK: Приложения

    struct RunningApp: Identifiable {
        let id: pid_t
        let name: String
        let icon: NSImage?
        let app: NSRunningApplication
    }

    var runningApps: [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleIdentifier != "com.apple.finder" }
            .map { RunningApp(id: $0.processIdentifier, name: $0.localizedName ?? String(localized: "Приложение"), icon: $0.icon, app: $0) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func forceQuit(_ a: RunningApp) {
        if demo { show("«\(a.name)» завершено (в демо — понарошку)"); return }
        if a.app.forceTerminate() { show("«\(a.name)» завершено") } else { show("Не получилось завершить «\(a.name)»") }
    }
}

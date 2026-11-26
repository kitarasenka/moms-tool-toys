import AppKit
import Foundation
import Observation

@MainActor @Observable
final class StartupStore {
    private(set) var jobs: [LaunchJob] = []
    private(set) var loginItems: [LoginItem] = []
    private(set) var loginAccess: LoginAccess = .unknown
    private(set) var loadingJobs = false
    private(set) var loadedOnce = false
    /// Службы, для которых сейчас выполняется действие (крутится индикатор вместо переключателя).
    private(set) var busy: Set<String> = []
    var errorMessage: String?

    func reloadJobs() async {
        loadingJobs = true
        jobs = await Task.detached(priority: .userInitiated) { StartupScanner.scanJobs() }.value
        loadingJobs = false
        loadedOnce = true
    }

    func setEnabled(_ job: LaunchJob, _ enabled: Bool) async {
        busy.insert(job.id)
        defer { busy.remove(job.id) }
        do {
            try await LaunchControl.setEnabled(job, enabled: enabled)
        } catch AdminRunner.Failure.cancelled {
        } catch {
            errorMessage = "«\(job.label)»: \(error.localizedDescription)"
        }
        await reloadJobs()
    }

    func moveToTrash(_ job: LaunchJob) async {
        do {
            try LaunchControl.moveToTrash(job)
        } catch {
            errorMessage = "Не удалось удалить «\(job.label)»: \(error.localizedDescription)"
        }
        await reloadJobs()
    }

    // MARK: Объекты входа

    /// Проверяет разрешение молча; если оно уже есть — загружает список.
    func refreshLoginItems() async {
        await LoginItemsService.launchSystemEvents()
        let access = await Task.detached { LoginItemsService.determineAccess(ask: false) }.value
        loginAccess = access
        if access == .granted { loadLoginItems() }
    }

    /// Явный запрос разрешения (показывает системный диалог).
    func requestLoginAccess() async {
        await LoginItemsService.launchSystemEvents()
        loginAccess = await Task.detached { LoginItemsService.determineAccess(ask: true) }.value
        if loginAccess == .granted { loadLoginItems() }
    }

    func loadLoginItems() {
        do {
            loginItems = try LoginItemsService.list()
            loginAccess = .granted
        } catch {
            loginAccess = .failed(error.localizedDescription)
        }
    }

    func addLoginItem(_ url: URL) {
        perform { try LoginItemsService.add(path: url.path) }
    }

    func removeLoginItem(_ item: LoginItem) {
        perform { try LoginItemsService.remove(item) }
    }

    func setHidden(_ item: LoginItem, _ hidden: Bool) {
        perform { try LoginItemsService.setHidden(item, hidden: hidden) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
        loadLoginItems()
    }
}

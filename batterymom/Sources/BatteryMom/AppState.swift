import AppKit
import Observation
import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable {
    case battery, history, energy, devices
}

@Observable @MainActor
final class AppState {
    var section: SidebarSection = .battery

    // Батарея
    var battery: BatteryInfo?
    var batteryUpdated: Date?
    /// `--no-battery`: показать интерфейс так, как его видит Mac без батареи (для проверки).
    var simulateNoBattery = false

    // Устройства
    var devices: [DeviceBattery] = []
    var devicesLoading = false
    var devicesUpdated: Date?

    // Расход приложений
    var energy: [AppEnergy] = []
    var energyLoading = false
    var energyUpdated: Date?

    /// Меняется после каждой записи в историю — экран «История» перечитывает файл.
    var historyTick = 0
    var lastRecorded: Date?

    private var started = false
    private var activity: NSObjectProtocol?

    var hasBattery: Bool { battery != nil }

    /// Запуск фоновой работы: опрос батареи, запись истории раз в минуту, устройства раз в 5 минут.
    /// Работает и при закрытом окне — BatteryMom остаётся в строке меню.
    func start() {
        guard !started else { return }
        started = true
        // Без этого App Nap растягивает минутный таймер, когда окно закрыто, и в истории появляются дыры.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Запись истории батареи")
        refreshBattery()
        PowerEvents.start { Task { @MainActor in self.refreshBattery() } }

        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                refreshBattery()
            }
        }
        Task {
            while !Task.isCancelled {
                record()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        Task {
            while !Task.isCancelled {
                await refreshDevices()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func refreshBattery() {
        battery = simulateNoBattery ? nil : BatteryReader.read()
        batteryUpdated = Date()
    }

    private func record() {
        refreshBattery()
        guard let b = battery else { return }
        let r = HistoryRecord(b)
        Task.detached(priority: .utility) {
            HistoryStore.shared.append(r)
            await MainActor.run {
                self.lastRecorded = r.t
                self.historyTick += 1
            }
        }
    }

    func refreshDevices() async {
        guard !devicesLoading else { return }
        devicesLoading = true
        devices = await Task.detached(priority: .userInitiated) { DeviceScanner.scan() }.value
        devicesUpdated = Date()
        devicesLoading = false
    }

    func refreshEnergy() async {
        guard !energyLoading else { return }
        energyLoading = true
        energy = await Task.detached(priority: .userInitiated) { EnergySampler.sample() }.value
        energyUpdated = Date()
        energyLoading = false
    }

    func refreshAll() async {
        refreshBattery()
        switch section {
        case .energy: await refreshEnergy()
        case .devices: await refreshDevices()
        default: break
        }
    }
}

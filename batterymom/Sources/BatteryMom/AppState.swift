import AppKit
import Observation
import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable {
    case battery, history, energy, devices
}

@Observable @MainActor
final class AppState {
    let demo: Bool
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

    init(demo: Bool = false) {
        self.demo = demo
    }

    /// Запуск фоновой работы: опрос батареи, запись истории раз в минуту, устройства раз в 5 минут.
    /// Работает и при закрытом окне — BatteryMom остаётся в строке меню.
    func start() {
        guard !started else { return }
        started = true
        if demo {
            refreshBattery()
            devices = [DeviceBattery(id: "mouse", name: "Magic Mouse", kind: .mouse,
                                     levels: [.init(percent: 72)], connected: true)]
            energy = [
                AppEnergy(id: "safari", name: "Safari", power: 9.3, processCount: 3),
                AppEnergy(id: "finder", name: "Finder", power: 1.5, processCount: 1),
            ]
            devicesUpdated = batteryUpdated
            energyUpdated = batteryUpdated
            return
        }
        // Без этого App Nap растягивает минутный таймер, когда окно закрыто, и в истории появляются дыры.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: String(localized: "Запись истории батареи"))
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
        if simulateNoBattery {
            battery = nil
        } else if demo {
            battery = BatteryInfo(percent: 76, isCharging: false, externalConnected: false, fullyCharged: false,
                                  minutesToEmpty: 224, cycleCount: 312, designCapacity: 8600, maxCapacity: 7568,
                                  currentCapacity: 5752, temperature: 32, voltage: 11.8, amperage: -1.6, systemLoad: 18.9)
        } else {
            battery = BatteryReader.read()
        }
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
        guard !demo, !devicesLoading else { return }
        devicesLoading = true
        devices = await Task.detached(priority: .userInitiated) { DeviceScanner.scan() }.value
        devicesUpdated = Date()
        devicesLoading = false
    }

    func refreshEnergy() async {
        guard !demo, !energyLoading else { return }
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

    func loadHistory(since: Date) async -> [HistoryRecord] {
        guard demo else {
            return await Task.detached(priority: .userInitiated) { HistoryStore.shared.load(since: since) }.value
        }
        let now = Date()
        return (0...24).map { i in
            let date = now.addingTimeInterval(Double(i - 24) * 1800)
            let percent = i < 12 ? 52 + 4 * i : 100 - 2 * (i - 12)
            return HistoryRecord(t: date, p: percent, c: i < 12, a: i < 12, w: 12 + Double(i % 7))
        }
    }
}

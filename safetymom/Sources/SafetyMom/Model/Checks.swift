import Foundation
import IOKit.ps

// MARK: - Светофор

enum Level: Int, Comparable, Sendable {
    case ok = 0, unknown = 1, warn = 2, danger = 3

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .ok: String(localized: "В порядке")
        case .unknown: String(localized: "Не удалось проверить")
        case .warn: String(localized: "Стоит поправить")
        case .danger: String(localized: "Важно исправить")
        }
    }
}

/// Одна проверка: что нашли, что это значит (простыми словами) и что сделать.
struct CheckResult: Identifiable, Sendable {
    var id: String
    var title: String
    var icon: String
    var level: Level
    var status: String          // коротко: «Включён», «Выключен», «3 дня назад»
    var explain: String         // что это значит
    var advice: String? = nil   // что сделать (если не в порядке)
    var link: SettingsLink? = nil
}

/// Итог всех проверок для шапки.
struct Verdict {
    var level: Level
    var title: String
    var subtitle: String

    init(_ checks: [CheckResult]) {
        let danger = checks.filter { $0.level == .danger }.count
        let warn = checks.filter { $0.level == .warn }.count
        let unknown = checks.filter { $0.level == .unknown }.count
        if danger > 0 {
            level = .danger
            title = String(localized: "Нужно исправить: \(Fmt.items(danger))")
        } else if warn > 0 {
            level = .warn
            title = String(localized: "В целом хорошо, но \(Fmt.itemsToReview(warn)) поправить")
        } else {
            level = .ok
            title = String(localized: "Mac защищён")
        }
        let okCount = checks.filter { $0.level == .ok }.count
        var s = String(localized: "В порядке \(okCount) из \(checks.count)")
        if unknown > 0 { s += String(localized: " · не удалось проверить \(unknown)") }
        subtitle = s
    }
}

// MARK: - Сами проверки

enum SystemChecks {
    /// Все проверки параллельно; каждая — со своим ограничением по времени.
    static func runAll() async -> [CheckResult] {
        let jobs: [@Sendable () -> CheckResult] = [
            { gatherUpdates() }, { gatherAutoUpdates() }, { gatherFileVault() }, { gatherFirewall() },
            { gatherGatekeeper() }, { gatherSIP() }, { gatherTimeMachine() }, { gatherScreenLock() },
            { gatherAutoLogin() }, { gatherRemote() }, { gatherXProtect() },
        ]
        return await withTaskGroup(of: (Int, CheckResult).self) { g in
            for (i, job) in jobs.enumerated() { g.addTask { (i, job()) } }
            var out: [(Int, CheckResult)] = []
            for await r in g { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Худшее — наверх, порядок внутри уровня сохраняется.
    static func sorted(_ list: [CheckResult]) -> [CheckResult] {
        list.enumerated().sorted { a, b in
            a.element.level != b.element.level ? a.element.level > b.element.level : a.offset < b.offset
        }.map(\.element)
    }

    private static func failed(_ id: String, _ title: String, _ icon: String, _ why: String, link: SettingsLink? = nil) -> CheckResult {
        CheckResult(id: id, title: title, icon: icon, level: .unknown, status: String(localized: "Не удалось проверить"), explain: why, link: link)
    }

    // MARK: FileVault

    static func gatherFileVault() -> CheckResult {
        let r = Shell.run("/usr/bin/fdesetup", ["status"])
        return fileVault(r.output, laptop: hasBattery)
    }

    static func fileVault(_ out: String, laptop: Bool) -> CheckResult {
        let id = "filevault", title = String(localized: "Шифрование диска (FileVault)"), icon = "lock.laptopcomputer"
        let o = out.lowercased()
        if o.contains("filevault is on") || o.contains("encryption in progress") {
            return CheckResult(id: id, title: title, icon: icon, level: .ok,
                               status: o.contains("progress") ? String(localized: "Включается…") : String(localized: "Включено"),
                               explain: String(localized: "Всё на диске зашифровано. Если Mac украдут, без вашего пароля файлы не прочитать."))
        }
        if o.contains("filevault is off") || o.contains("decryption in progress") {
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "Выключено"),
                               explain: laptop
                                   ? String(localized: "Если ноутбук потеряется или его украдут, чужой человек сможет прочитать ваши фото, документы и переписку, даже не зная пароля.")
                                   : String(localized: "Если компьютер унесут, чужой человек сможет прочитать файлы с диска, не зная пароля."),
                               advice: String(localized: "Включите FileVault. Mac будет шифровать диск в фоне, работать можно как обычно. Ключ восстановления сохраните в iCloud или запишите на бумаге."),
                               link: .fileVault)
        }
        return failed(id, title, icon, String(localized: "macOS не ответила, включено ли шифрование."), link: .fileVault)
    }

    static var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { src in
            let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any]
            return (d?[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }
    }

    // MARK: Файрвол

    static func gatherFirewall() -> CheckResult {
        firewall(Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).output)
    }

    static func firewall(_ out: String) -> CheckResult {
        let id = "firewall", title = String(localized: "Файрвол"), icon = "flame"
        let o = out.lowercased()
        if o.contains("enabled") || o.contains("state = 1") || o.contains("state = 2") {
            return CheckResult(id: id, title: title, icon: icon, level: .ok, status: String(localized: "Включён"),
                               explain: String(localized: "Mac не принимает непрошеные подключения из сети — например, в кафе или гостинице."))
        }
        if o.contains("disabled") || o.contains("state = 0") {
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "Выключен"),
                               explain: String(localized: "Дома за роутером это не страшно, но в чужих сетях (кафе, гостиница, аэропорт) Mac виден другим устройствам."),
                               advice: String(localized: "Включите файрвол — обычным программам он не мешает."), link: .firewall)
        }
        return failed(id, title, icon, String(localized: "Не получилось узнать состояние файрвола."), link: .firewall)
    }

    // MARK: Gatekeeper

    static func gatherGatekeeper() -> CheckResult { gatekeeper(Shell.run("/usr/sbin/spctl", ["--status"]).output) }

    static func gatekeeper(_ out: String) -> CheckResult {
        let id = "gatekeeper", title = String(localized: "Проверка программ (Gatekeeper)"), icon = "checkmark.seal"
        let o = out.lowercased()
        if o.contains("assessments enabled") {
            return CheckResult(id: id, title: title, icon: icon, level: .ok, status: String(localized: "Включена"),
                               explain: String(localized: "Перед первым запуском macOS проверяет, что программа подписана разработчиком и проверена Apple."))
        }
        if o.contains("assessments disabled") {
            return CheckResult(id: id, title: title, icon: icon, level: .danger, status: String(localized: "Выключена"),
                               explain: String(localized: "Mac запускает любые программы без проверки — так чаще всего и попадают вирусы и «рекламные» программы."),
                               advice: String(localized: "В «Конфиденциальность и безопасность» выберите «Разрешать приложения из App Store и от известных разработчиков». Если не получается — попросите помощи у того, кто настраивал Mac."),
                               link: .security)
        }
        return failed(id, title, icon, String(localized: "Не получилось узнать состояние Gatekeeper."))
    }

    // MARK: SIP

    static func gatherSIP() -> CheckResult { sip(Shell.run("/usr/bin/csrutil", ["status"]).output) }

    static func sip(_ out: String) -> CheckResult {
        let id = "sip", title = String(localized: "Защита системных файлов (SIP)"), icon = "shield.lefthalf.filled"
        let o = out.lowercased()
        if o.contains("status: enabled") {
            return CheckResult(id: id, title: title, icon: icon, level: .ok, status: String(localized: "Включена"),
                               explain: String(localized: "Ни одна программа, даже с паролем администратора, не может испортить системные файлы macOS."))
        }
        if o.contains("status: disabled") || o.contains("custom configuration") {
            return CheckResult(id: id, title: title, icon: icon, level: .danger,
                               status: o.contains("custom") ? String(localized: "Частично выключена") : String(localized: "Выключена"),
                               explain: String(localized: "Защита системы ослаблена. Обычно её выключают только разработчики; вредоносной программе так проще закрепиться в системе."),
                               advice: String(localized: "Если вы сами её не выключали — попросите знакомого специалиста включить её обратно (это делается из режима восстановления, командой «csrutil enable»)."))
        }
        return failed(id, title, icon, String(localized: "Не получилось узнать состояние защиты системы."))
    }

    // MARK: Обновления

    static let softwareUpdatePlist = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
    static let commercePlist = "/Library/Preferences/com.apple.commerce.plist"

    static func gatherUpdates() -> CheckResult {
        updates(prefs: Plist.read(softwareUpdatePlist), current: ProcessInfo.processInfo.operatingSystemVersion, now: .now)
    }

    /// Порядковый номер версии macOS: после 15 (Sequoia) Apple перешла на 26 (Tahoe), поэтому
    /// «на сколько поколений отстаём» считаем по порядку, а не вычитанием номеров.
    static func generation(_ major: Int) -> Int { major <= 15 ? major : major - 10 }

    static func parseVersion(_ s: String) -> [Int] { s.split(separator: ".").compactMap { Int($0) } }

    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func updates(prefs: [String: Any]?, current: OperatingSystemVersion, now: Date) -> CheckResult {
        let id = "updates", title = String(localized: "Обновления macOS"), icon = "arrow.triangle.2.circlepath"
        let cur = [current.majorVersion, current.minorVersion, current.patchVersion]
        let curText = "macOS \(current.majorVersion).\(current.minorVersion)" + (current.patchVersion > 0 ? ".\(current.patchVersion)" : "")
        guard let prefs else {
            return failed(id, title, icon, String(localized: "Сейчас установлена \(curText). Список доступных обновлений прочитать не удалось."), link: .softwareUpdate)
        }
        let recommended = (prefs["RecommendedUpdates"] as? [[String: Any]]) ?? []
        var sameMajor: [String] = [], newerMajors: [Int] = [], others: [String] = []
        for u in recommended {
            let name = (u["Display Name"] as? String ?? "").replacingOccurrences(of: "\u{a0}", with: " ")
            let ver = u["Display Version"] as? String ?? ""
            let ident = u["Identifier"] as? String ?? ""
            let isOS = name.lowercased().contains("macos") || ident.hasPrefix("MSU_UPDATE")
            let v = parseVersion(ver)
            if isOS, let major = v.first {
                if major == current.majorVersion, isNewer(v, than: cur) { sameMajor.append(ver) }
                else if major > current.majorVersion { newerMajors.append(major) }
            } else if !name.isEmpty {
                others.append(name)
            }
        }
        let behind = (newerMajors.max().map { generation($0) } ?? generation(current.majorVersion)) - generation(current.majorVersion)
        let lastCheck = prefs["LastSuccessfulDate"] as? Date ?? prefs["LastFullSuccessfulDate"] as? Date
        let latestMinor = sameMajor.max { isNewer(parseVersion($1), than: parseVersion($0)) }

        if behind >= 3 {
            return CheckResult(id: id, title: title, icon: icon, level: .danger, status: String(localized: "\(curText) устарела"),
                               explain: String(localized: "Apple выпускает исправления безопасности только для трёх последних версий macOS. Эта версия их больше не получает."),
                               advice: String(localized: "Обновите macOS в «Обновлении ПО». Если Mac не предлагает новую версию — он слишком старый для неё; тогда особенно важно не ставить программы из непроверенных мест."),
                               link: .softwareUpdate)
        }
        if let latestMinor {
            var adv = String(localized: "Откройте «Обновление ПО» и нажмите «Обновить сейчас» — Mac перезагрузится, всё ваше останется на месте.")
            if !others.isEmpty { adv += String(localized: " Там же ждут: \(others.prefix(3).joined(separator: ", ")).") }
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "Есть обновление \(latestMinor)"),
                               explain: String(localized: "Сейчас установлена \(curText). В обновлениях Apple закрывает дыры, через которые могут заразить Mac."),
                               advice: adv, link: .softwareUpdate)
        }
        if let lastCheck, now.timeIntervalSince(lastCheck) > 30 * 86400 {
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "Давно не проверялись"),
                               explain: String(localized: "Последний раз Mac искал обновления \(Fmt.ago(lastCheck, now: now)). Возможно, новые уже вышли."),
                               advice: String(localized: "Откройте «Обновление ПО» — Mac проверит сразу."), link: .softwareUpdate)
        }
        var explain = String(localized: "Установлена \(curText) — последние исправления на месте.")
        if let lastCheck { explain += String(localized: " Проверено \(Fmt.ago(lastCheck, now: now)).") }
        if !newerMajors.isEmpty { explain += String(localized: " Можно перейти и на новую версию macOS, но это не обязательно.") }
        return CheckResult(id: id, title: title, icon: icon, level: .ok, status: String(localized: "Всё установлено"), explain: explain)
    }

    static func gatherAutoUpdates() -> CheckResult {
        autoUpdates(prefs: Plist.read(softwareUpdatePlist), commerce: Plist.read(commercePlist))
    }

    static func autoUpdates(prefs: [String: Any]?, commerce: [String: Any]?) -> CheckResult {
        let id = "autoupdate", title = String(localized: "Автоматические обновления"), icon = "arrow.down.circle"
        guard let prefs else { return failed(id, title, icon, String(localized: "Настройки обновлений прочитать не удалось."), link: .softwareUpdate) }
        // Если ключа нет, macOS считает настройку включённой.
        let security = prefs.bool("CriticalUpdateInstall") ?? true
        let data = prefs.bool("ConfigDataInstall") ?? true
        let check = prefs.bool("AutomaticCheckEnabled") ?? true
        let appStore = commerce?.bool("AutoUpdate")
        if !security || !data {
            return CheckResult(id: id, title: title, icon: icon, level: .danger, status: String(localized: "Защита не обновляется"),
                               explain: String(localized: "Выключена установка «Ответов системы безопасности» и файлов защиты от вирусов. Mac не узнаёт о новых угрозах."),
                               advice: String(localized: "В «Обновлении ПО» → «Автоматические обновления» включите «Устанавливать ответы системы безопасности и системные файлы»."),
                               link: .softwareUpdate)
        }
        if !check {
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "Проверка выключена"),
                               explain: String(localized: "Mac сам не ищет обновления — о новых исправлениях вы не узнаете."),
                               advice: String(localized: "Включите «Проверять наличие обновлений» в «Автоматических обновлениях»."), link: .softwareUpdate)
        }
        if appStore == false {
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "App Store — вручную"),
                               explain: String(localized: "Защита macOS обновляется сама, а программы из App Store — нет: старые версии могут содержать известные дыры."),
                               advice: String(localized: "В «Автоматических обновлениях» включите «Устанавливать обновления приложений из App Store»."),
                               link: .softwareUpdate)
        }
        return CheckResult(id: id, title: title, icon: icon, level: .ok, status: String(localized: "Включены"),
                           explain: String(localized: "Исправления безопасности и файлы защиты от вирусов приходят сами."))
    }

    // MARK: XProtect

    static let xprotectBundle = "/Library/Apple/System/Library/CoreServices/XProtect.bundle"

    static func gatherXProtect() -> CheckResult {
        let info = Plist.read(xprotectBundle + "/Contents/Info.plist")
        let fm = FileManager.default
        let dates = ["/Contents/Info.plist", "/Contents/version.plist", "/Contents/Resources/XProtect.yara"]
            .compactMap { (try? fm.attributesOfItem(atPath: xprotectBundle + $0))?[.modificationDate] as? Date }
        return xprotect(version: info?["CFBundleShortVersionString"] as? String, updated: dates.max(), now: .now)
    }

    static func xprotect(version: String?, updated: Date?, now: Date) -> CheckResult {
        let id = "xprotect", title = String(localized: "Встроенный антивирус (XProtect)"), icon = "cross.case"
        guard let version else { return failed(id, title, icon, String(localized: "Не нашлась база XProtect."), link: .softwareUpdate) }
        let explain = String(localized: "macOS сама проверяет программы по базе известных вирусов. Версия базы — \(version)")
            + (updated.map { String(localized: ", обновлена \(Fmt.date($0)).") } ?? ".")
        if let updated, now.timeIntervalSince(updated) > 90 * 86400 {
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "База давно не обновлялась"),
                               explain: explain + String(localized: " Обычно Apple обновляет её раз в несколько недель."),
                               advice: String(localized: "Проверьте, что включены «Ответы системы безопасности и системные файлы» и что Mac подключён к интернету."),
                               link: .softwareUpdate)
        }
        return CheckResult(id: id, title: title, icon: icon, level: .ok,
                           status: updated.map { String(localized: "Обновлена \(Fmt.ago($0, now: now))") } ?? String(localized: "Версия \(version)"), explain: explain)
    }

    // MARK: Time Machine

    static let timeMachinePlist = "/Library/Preferences/com.apple.TimeMachine.plist"

    static func gatherTimeMachine() -> CheckResult {
        let prefs = Plist.read(timeMachinePlist)
        let info = Shell.run("/usr/bin/tmutil", ["destinationinfo"], timeout: 8)
        return timeMachine(prefs: prefs, readable: Plist.readable(timeMachinePlist) || prefs != nil,
                           destinationInfo: info.timedOut ? nil : info.output, now: .now)
    }

    /// Имена дисков из `tmutil destinationinfo` («Name : Backup»).
    static func destinationNames(_ out: String) -> [String] {
        out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == "Name" ? parts[1] : nil
        }
    }

    static func timeMachine(prefs: [String: Any]?, readable: Bool, destinationInfo: String?, now: Date) -> CheckResult {
        let id = "timemachine", title = String(localized: "Резервная копия (Time Machine)"), icon = "clock.arrow.circlepath"
        let dests = (prefs?["Destinations"] as? [[String: Any]]) ?? []
        let names = destinationInfo.map(destinationNames) ?? []
        let noneConfigured = (destinationInfo?.lowercased().contains("no destinations") ?? false) || (prefs != nil && dests.isEmpty && names.isEmpty)
        if noneConfigured {
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "Не настроена"),
                               explain: String(localized: "Копий нет. Если диск сломается, Mac украдут или вирус-вымогатель зашифрует файлы — фото и документы пропадут навсегда (кроме того, что лежит в iCloud)."),
                               advice: String(localized: "Купите внешний диск (от 1 ТБ), подключите его и в настройках Time Machine нажмите «Добавить резервный диск». Дальше Mac будет делать копии сам, когда диск подключён."),
                               link: .timeMachine)
        }
        guard prefs != nil || !names.isEmpty else {
            return failed(id, title, icon, readable ? String(localized: "Не удалось прочитать настройки Time Machine.")
                          : String(localized: "Настройки Time Machine закрыты системой — нужен полный доступ к диску."),
                          link: readable ? .timeMachine : .fullDisk)
        }
        var dates: [Date] = []
        for d in dests {
            if let s = d["SnapshotDates"] as? [Date] { dates += s }
            if let r = d["ReferenceLocalSnapshotDate"] as? Date { dates.append(r) }
        }
        let latest = dates.max()
        let auto = prefs?.bool("AutoBackup") ?? true
        let diskName = names.first.map { "«\($0)»" } ?? String(localized: "диск")
        guard let latest else {
            return CheckResult(id: id, title: title, icon: icon, level: .unknown, status: String(localized: "Диск выбран"),
                               explain: String(localized: "Для копий выбран \(diskName), но когда была последняя копия, узнать не удалось."),
                               advice: String(localized: "Откройте настройки Time Machine — там видно дату последней копии."), link: .timeMachine)
        }
        let age = now.timeIntervalSince(latest)
        let when = Fmt.ago(latest, now: now)
        if !auto {
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "Только вручную"),
                               explain: String(localized: "Последняя копия — \(when). Автоматические копии выключены."),
                               advice: String(localized: "Включите автоматическое резервное копирование в настройках Time Machine."), link: .timeMachine)
        }
        if age > 30 * 86400 {
            return CheckResult(id: id, title: title, icon: icon, level: .danger, status: String(localized: "Последняя — \(when)"),
                               explain: String(localized: "Больше месяца без копии: всё, что появилось за это время, некуда будет восстановить."),
                               advice: String(localized: "Подключите \(diskName) — Time Machine сделает копию сама. Или нажмите «Создать резервную копию» в меню Time Machine."),
                               link: .timeMachine)
        }
        if age > 7 * 86400 {
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "Последняя — \(when)"),
                               explain: String(localized: "Копия есть, но не свежая."),
                               advice: String(localized: "Подключайте \(diskName) хотя бы раз в неделю."), link: .timeMachine)
        }
        return CheckResult(id: id, title: title, icon: icon, level: .ok, status: String(localized: "Последняя — \(when)"),
                           explain: String(localized: "Копии делаются на \(diskName). Если что-то случится, файлы можно будет вернуть."))
    }

    // MARK: Экран блокировки

    static func gatherScreenLock() -> CheckResult {
        let r = Shell.run("/usr/sbin/sysadminctl", ["-screenLock", "status"])
        let idle = Shell.run("/usr/bin/defaults", ["-currentHost", "read", "com.apple.screensaver", "idleTime"])
        let pm = Shell.run("/usr/bin/pmset", ["-g"])
        return screenLock(r.output, screensaverIdle: idle.ok ? Int(idle.output) : nil, displaySleep: displaySleep(pm.output))
    }

    /// `displaysleep 10` из `pmset -g` (минуты; 0 — никогда).
    static func displaySleep(_ out: String) -> Int? {
        for line in out.split(separator: "\n") {
            let p = line.split(whereSeparator: \.isWhitespace)
            if p.count >= 2, p[0] == "displaysleep" { return Int(p[1]) }
        }
        return nil
    }

    static func screenLock(_ out: String, screensaverIdle: Int?, displaySleep: Int?) -> CheckResult {
        let id = "screenlock", title = String(localized: "Пароль после сна"), icon = "lock.display"
        let o = out.lowercased()
        let neverSleeps = (displaySleep == 0) && (screensaverIdle ?? 0) == 0
        var delay: Int?
        if o.contains("delay is immediate") { delay = 0 }
        else if let r = o.range(of: "delay is ") {
            delay = Int(o[r.upperBound...].prefix { $0.isNumber })
        }
        if o.contains("screenlock is off") {
            return CheckResult(id: id, title: title, icon: icon, level: .danger, status: String(localized: "Не спрашивается"),
                               explain: String(localized: "Когда Mac просыпается или включается заставка, пароль не нужен — кто угодно может сесть и пользоваться вашими почтой и банком."),
                               advice: String(localized: "В «Экране блокировки» выберите «Запрашивать пароль после включения заставки или выключения дисплея» — «Сразу»."),
                               link: .lockScreen)
        }
        guard let delay else { return failed(id, title, icon, String(localized: "macOS не ответила, когда спрашивается пароль."), link: .lockScreen) }
        let after = delay == 0 ? String(localized: "сразу") : (delay < 60 ? String(localized: "через \(delay) с") : String(localized: "через \(delay / 60) мин"))
        if delay > 300 {
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "Пароль \(after)"),
                               explain: String(localized: "Пока не прошло это время, разбудить Mac можно без пароля."),
                               advice: String(localized: "Поставьте «Сразу» или «Через 5 минут»."), link: .lockScreen)
        }
        if neverSleeps {
            return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "Экран не гаснет"),
                               explain: String(localized: "Пароль спрашивается \(after), но экран никогда не гаснет сам — оставленный Mac так и останется открытым."),
                               advice: String(localized: "В «Экране блокировки» задайте, через сколько выключать дисплей (например, 10 минут)."),
                               link: .lockScreen)
        }
        return CheckResult(id: id, title: title, icon: icon, level: .ok, status: String(localized: "Пароль \(after)"),
                           explain: String(localized: "Отошли от Mac — без пароля им не воспользоваться."))
    }

    // MARK: Автовход

    static let loginWindowPlist = "/Library/Preferences/com.apple.loginwindow.plist"

    static func gatherAutoLogin() -> CheckResult {
        autoLogin(Plist.read(loginWindowPlist), readable: Plist.readable(loginWindowPlist))
    }

    static func autoLogin(_ prefs: [String: Any]?, readable: Bool) -> CheckResult {
        let id = "autologin", title = String(localized: "Вход без пароля"), icon = "person.badge.key"
        guard prefs != nil || !readable else { return failed(id, title, icon, String(localized: "Настройки входа прочитать не удалось."), link: .users) }
        if let user = prefs?["autoLoginUser"] as? String, !user.isEmpty {
            return CheckResult(id: id, title: title, icon: icon, level: .danger, status: String(localized: "Включён для «\(user)»"),
                               explain: String(localized: "После включения Mac сразу открывает вашу учётную запись — пароль не нужен никому."),
                               advice: String(localized: "В «Пользователях и группах» поставьте «Автоматически входить как» → «Выкл.»."), link: .users)
        }
        return CheckResult(id: id, title: title, icon: icon, level: .ok, status: String(localized: "Выключен"),
                           explain: String(localized: "После включения Mac спрашивает пароль."))
    }

    // MARK: Удалённый доступ

    struct RemoteService: Sendable {
        var port: UInt16
        var name: String
    }

    static let remoteServices: [RemoteService] = [
        .init(port: 22, name: String(localized: "Удалённый вход (SSH)")),
        .init(port: 5900, name: String(localized: "Общий экран / удалённое управление")),
        .init(port: 3283, name: String(localized: "Удалённое управление (Apple Remote Desktop)")),
        .init(port: 445, name: String(localized: "Общий доступ к файлам")),
    ]

    static func gatherRemote() -> CheckResult {
        remote(open: Set(remoteServices.map(\.port).filter { Ports.isListening($0) }))
    }

    static func remote(open: Set<UInt16>) -> CheckResult {
        let id = "remote", title = String(localized: "Удалённый доступ"), icon = "display.2"
        let on = remoteServices.filter { open.contains($0.port) }.map(\.name)
        if on.isEmpty {
            return CheckResult(id: id, title: title, icon: icon, level: .ok, status: String(localized: "Выключен"),
                               explain: String(localized: "К этому Mac нельзя подключиться по сети: общий экран, удалённый вход и общие папки выключены."))
        }
        return CheckResult(id: id, title: title, icon: icon, level: .warn, status: String(localized: "Включено: \(on.count)"),
                           explain: String(localized: "Включено: \(on.joined(separator: ", ")). Через это можно управлять Mac или читать файлы с другого компьютера."),
                           advice: String(localized: "Если вы это не включали сами и вам не помогает кто-то из близких — выключите в «Общем доступе». Мошенники «из техподдержки банка» часто просят включить именно это."),
                           link: .sharing)
    }
}

// MARK: - Порты

enum Ports {
    /// Слушает ли кто-то порт на этом Mac: пробное подключение к 127.0.0.1 с коротким тайм-аутом.
    /// Пароль администратора не нужен, запросов на экране нет.
    static func isListening(_ port: UInt16, timeoutMs: Int32 = 400) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
}

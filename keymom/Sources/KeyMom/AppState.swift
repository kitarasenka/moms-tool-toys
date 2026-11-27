import AppKit
import Observation
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case guide, convert, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guide: String(localized: "Как пользоваться")
        case .convert: String(localized: "Исправить текст")
        case .settings: String(localized: "Настройки")
        }
    }

    var icon: String {
        switch self {
        case .guide: "questionmark.circle"
        case .convert: "character.cursor.ibeam"
        case .settings: "gearshape"
        }
    }
}

/// Доступ к общему буферу (macOS 15.4+, на macOS 26 — «Вставка из других приложений»).
/// Нужен только запасному способу исправления (⌘C/⌘V), когда приложение не отдаёт текст напрямую.
enum PasteAccess: Equatable {
    case unsupported, notAsked, ask, allowed, denied

    static func current() -> PasteAccess {
        guard #available(macOS 15.4, *) else { return .unsupported }
        switch NSPasteboard.general.accessBehavior {
        case .default: return .notAsked
        case .ask: return .ask
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        @unknown default: return .ask
        }
    }

    var title: String {
        switch self {
        case .unsupported, .allowed: String(localized: "Разрешён")
        case .notAsked: String(localized: "macOS спросит один раз")
        case .ask: String(localized: "macOS спрашивает каждый раз")
        case .denied: String(localized: "Запрещён")
        }
    }

    static func openSettings() {
        let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard",
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }
}

/// Состояние: раскладка, Caps Lock, сочетание, исправление текста в чужих приложениях.
@MainActor
@Observable
final class AppState {
    let demo: Bool
    let prefs: Preferences

    var section: Page = .guide
    var current: InputSourceInfo?
    var capsOn = false
    var secureInput = false
    var axTrusted = Accessibility.trusted
    var pasteAccess = PasteAccess.unsupported
    var hotkeyFailed = false
    var busy = false
    /// Последнее исправление: «ghbdtn → привет».
    var lastFix: String?
    var detectedVariant: RussianVariant = .pc
    /// `--hud …` в демо: показанную плашку не прятать по опросу Caps Lock.
    @ObservationIgnored var pinnedHUD = false

    // Поля окна
    var tryText = ""
    var convertInput = ""
    var convertDirection: Direction?  // nil — автоматически

    @ObservationIgnored private let hotKey = HotKey()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var askedTrust = false
    @ObservationIgnored private var started = false
    @ObservationIgnored let flash = HUD()
    @ObservationIgnored let warning = HUD()

    init(demo: Bool) {
        self.demo = demo
        prefs = Preferences(defaults: demo ? nil : .standard)
        if demo {
            let v = InputSources.detectRussianVariant()
            tryText = LayoutConverter.convert("Привет, как дела?", direction: .toEnglish, variant: v)  // l10n:skip
            convertInput = "Pfdnhf d 10:30 r dhfxe - yt pf,elm gjkbc!"
        }
        DispatchQueue.main.async { self.start() }
    }

    /// Русская раскладка для перевода: из настроек или определённая по включённым раскладкам.
    var variant: RussianVariant {
        switch prefs.variant {
        case .auto: detectedVariant
        case .pc: .pc
        case .mac: .mac
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        refreshLayout(showHUD: false)
        capsOn = KeyboardState.capsLock
        pasteAccess = PasteAccess.current()
        HotKey.onPress = { [weak self] in Task { @MainActor in await self?.fixLayout() } }
        if !demo { applyHotkey() }
        InputSourceObserver.onChange = { [weak self] in self?.refreshLayout(showHUD: true) }
        InputSourceObserver.install()
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Сочетание

    func applyHotkey() {
        hotKey.unregister()
        hotkeyFailed = false
        guard prefs.hotkeyEnabled, !demo else { return }
        hotkeyFailed = !hotKey.register(prefs.hotkey)
    }

    func setHotkeyEnabled(_ on: Bool) {
        prefs.hotkeyEnabled = on
        applyHotkey()
        if on && !Accessibility.trusted { askTrust() }
    }

    func setHotkey(_ p: HotkeyPreset) {
        prefs.hotkey = p
        applyHotkey()
    }

    func askTrust() {
        Accessibility.requestTrust()
        askedTrust = true
    }

    // MARK: Раскладка и Caps Lock

    private func refreshLayout(showHUD: Bool) {
        let new = InputSources.current()
        let changed = new?.id != current?.id
        current = new
        if prefs.variant == .auto { detectedVariant = InputSources.detectRussianVariant() }
        if changed && showHUD && prefs.layoutHUD, let new {
            flash.show(HUDMessage(title: new.code, flag: new.flag, subtitle: new.name, style: .layout), duration: 0.8)
        }
    }

    private func tick() {
        ticks += 1
        // Подстраховка к уведомлению: раскладку сверяем и опросом (раз в ~0,6 с).
        if ticks % 2 == 0, InputSources.current()?.id != current?.id { refreshLayout(showHUD: true) }

        let caps = KeyboardState.capsLock
        let secure = KeyboardState.secureInput
        if caps != capsOn {
            capsOn = caps
            if prefs.capsHUD && !pinnedHUD {
                if caps {
                    flash.show(HUDMessage(title: "Caps Lock", flag: "⇪", subtitle: String(localized: "Включён — буквы будут ЗАГЛАВНЫЕ"), style: .caps),
                               duration: 1.4)
                } else {
                    flash.show(HUDMessage(title: "Caps Lock", flag: "⇪", subtitle: String(localized: "Выключен"), style: .layout), duration: 0.7)
                }
            }
        }
        secureInput = secure
        if pinnedHUD {
            // плашку для скриншота держим, пока не уберут
        } else if caps && secure && prefs.capsPasswordWarning {
            if warning.isVisible {
                warning.follow()
            } else {
                flash.hide()
                warning.show(HUDMessage(title: String(localized: "Включён Caps Lock"), flag: "⚠️",
                                        subtitle: String(localized: "Пароль может не подойти — нажмите ⇪, чтобы выключить"), style: .warning),
                             duration: nil)
            }
        } else if warning.isVisible {
            warning.hide()
        }

        if ticks % 7 == 0 {
            let t = Accessibility.trusted
            if t != axTrusted { axTrusted = t }
        }
        if ticks % 20 == 0 {
            let a = PasteAccess.current()
            if a != pasteAccess { pasteAccess = a }
        }
    }

    // MARK: Исправление

    /// Перевод в окне: направление из переключателя или автоматически.
    func converted(_ text: String) -> (String, Direction)? {
        if let d = convertDirection {
            return (LayoutConverter.convert(text, direction: d, variant: variant), d)
        }
        return LayoutConverter.autoConvert(text, variant: variant)
    }

    /// Поле «Попробуйте» в окне: исправить без чужих приложений и разрешений.
    func fixTryField() {
        guard let r = LayoutConverter.autoConvert(tryText, variant: variant) else { NSSound.beep(); return }
        let (fixed, d) = r
        lastFix = "\(tryText) → \(fixed)"
        tryText = fixed
        if prefs.switchLayout && !demo { InputSources.select(language: d.targetLanguage, preferRussian: variant) }
    }

    func copy(_ s: String) {
        PasteboardWriter.writePlain(s, to: .general)
        flash.show(HUDMessage(title: String(localized: "Скопировано"), flag: "✓", subtitle: nil, style: .success), duration: 0.8)
    }

    /// Сочетание нажато: исправить выделение или слово перед курсором в активном приложении.
    func fixLayout() async {
        guard !busy else { return }
        // Окно KeyMom впереди и курсор в поле «Попробуйте» — исправляем прямо там.
        if NSApp.isActive, NSApp.keyWindow?.firstResponder is NSTextView, section == .guide, !tryText.isEmpty {
            fixTryField()
            return
        }
        if demo {
            flash.show(HUDMessage(title: String(localized: "Демо"), flag: "ℹ️", subtitle: String(localized: "В демо-режиме чужие окна не меняются"), style: .layout),
                       duration: 1.2)
            return
        }
        axTrusted = Accessibility.trusted
        guard axTrusted else {
            if !askedTrust { askTrust() }
            flash.show(HUDMessage(title: String(localized: "Нужно разрешение"), flag: "🔒",
                                  subtitle: String(localized: "Включите KeyMom в «Универсальном доступе»"), style: .warning), duration: 2.5)
            section = .guide
            AppDelegate.openMain?()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        busy = true
        defer { busy = false }
        // Дождаться, пока отпустят ⇧⌘ — иначе наши ⌘C/⌘V смешаются с зажатыми клавишами.
        for _ in 0..<50 where KeyPress.modifiersHeld { try? await Task.sleep(for: .milliseconds(20)) }

        let variant = self.variant
        // 1. Напрямую через Accessibility — буфер обмена не трогаем.
        let target = AXText.target()
        if let target {
            guard let r = LayoutConverter.autoConvert(target.text, variant: variant) else { nothing(); return }
            let (fixed, d) = r
            switch await AXText.replace(target, with: fixed) {
            case .replaced:
                done(target.text, fixed, d)
            case .unchanged:
                // Приложение не дало заменить напрямую, исходный текст на месте — выделим его и вставим через буфер.
                AXText.setSelectedRange(target.element, target.range)
                if await pasteFallback(fixed, original: nil) { done(target.text, fixed, d) }
            case .unknown:
                // Текст уже изменился, но прочитать результат не удалось: повторная вставка задвоила бы слово.
                done(target.text, fixed, d)
            }
            return
        }
        // 2. Запасной путь: ⌘C (или ⌥⇧← + ⌘C) и ⌘V через буфер обмена.
        guard pasteAccess != .denied else {
            flash.show(HUDMessage(title: String(localized: "Не получилось"), flag: "⚠️",
                                  subtitle: String(localized: "Это приложение не отдаёт текст, а буфер обмена для KeyMom запрещён"), style: .warning),
                       duration: 2.5)
            return
        }
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.take(pb)
        var text = await copySelection(pb)
        // VS Code, JetBrains, Sublime: ⌘C без выделения копирует всю строку с переводом строки в конце —
        // это не выделение, иначе исправленная строка вставится у курсора второй раз.
        if let t = text, ClipText.looksLikeWholeLineCopy(t) { text = nil }
        if text?.isEmpty ?? true {
            KeyPress.selectWordLeft()
            try? await Task.sleep(for: .milliseconds(60))
            text = await copySelection(pb)
            // Курсор в начале строки — ⌥⇧← ничего не выделил, и редактор снова скопировал всю строку.
            if let t = text, ClipText.looksLikeWholeLineCopy(t) { text = nil }
        }
        guard let text, let r = LayoutConverter.autoConvert(text, variant: variant) else {
            snapshot.restore(to: pb)
            nothing()
            return
        }
        let (fixed, d) = r
        if await pasteFallback(fixed, original: snapshot) { done(text, fixed, d) }
    }

    /// ⌘C и ждём, пока приложение положит выделенное в буфер (до ~0,4 с).
    private func copySelection(_ pb: NSPasteboard) async -> String? {
        let before = pb.changeCount
        KeyPress.copy()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(20))
            if pb.changeCount != before { return pb.string(forType: .string) }
        }
        return nil
    }

    /// Кладёт исправленное в буфер (помечено «не записывать»), жмёт ⌘V и возвращает прежнее содержимое.
    private func pasteFallback(_ fixed: String, original: PasteboardSnapshot?) async -> Bool {
        let pb = NSPasteboard.general
        let snapshot = original ?? PasteboardSnapshot.take(pb)
        PasteboardWriter.writeTransient(fixed, to: pb)
        KeyPress.paste()
        // Приложение читает буфер при вставке не сразу — даём время, потом возвращаем как было.
        try? await Task.sleep(for: .milliseconds(400))
        snapshot.restore(to: pb)
        return true
    }

    private func nothing() {
        NSSound.beep()
        flash.show(HUDMessage(title: String(localized: "Нечего исправлять"), flag: "🤷", subtitle: String(localized: "Выделите текст или поставьте курсор после слова"),
                              style: .layout), duration: 1.4)
    }

    private func done(_ from: String, _ to: String, _ d: Direction) {
        lastFix = "\(from.trimmingCharacters(in: .whitespaces)) → \(to.trimmingCharacters(in: .whitespaces))"
        if prefs.switchLayout {
            InputSources.select(language: d.targetLanguage, preferRussian: variant)
            refreshLayout(showHUD: false)
        }
        flash.show(HUDMessage(title: d == .toRussian ? "RU" : "EN", flag: d == .toRussian ? "🇷🇺" : "🇺🇸",
                              subtitle: String(localized: "Исправлено: \(to.count > 28 ? String(to.prefix(27)) + "…" : to)"), style: .success),
                   duration: 1.0)
    }

    // MARK: Dock

    func setShowInDock(_ on: Bool) {
        prefs.showInDock = on
        Self.applyDockPolicy(on)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    static func applyDockPolicy(_ showInDock: Bool) {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}

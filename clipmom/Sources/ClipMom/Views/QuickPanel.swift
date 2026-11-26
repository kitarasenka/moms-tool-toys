import AppKit
import Observation
import SwiftUI

/// Плавающая панель, которая берёт клавиатуру, но не активирует ClipMom: приложение, где был
/// пользователь, остаётся активным — туда и уйдёт ⌘V при «Вставлять сразу».
final class QuickPanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }
}

@Observable
final class QuickModel {
    var query = ""
    var index = 0
    var focusToken = 0
}

@MainActor
final class QuickPanelController {
    private unowned let state: AppState
    private var panel: QuickPanel?
    private let model = QuickModel()
    private var keyMonitor: Any?

    init(state: AppState) { self.state = state }

    var isVisible: Bool { panel?.isVisible == true }

    func results() -> [ClipItem] {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? state.items : state.items.filter { $0.searchText.localizedCaseInsensitiveContains(q) }
        return Array(list.prefix(50))
    }

    func toggle() { isVisible ? close() : show() }

    func show() {
        model.query = ""
        model.index = 0
        let p = panel ?? makePanel()
        panel = p
        let size = p.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        if origin.y < vf.minY { origin.y = min(mouse.y + 12, vf.maxY - size.height) }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        p.setFrameOrigin(origin)
        p.makeKeyAndOrderFront(nil)
        model.focusToken += 1
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    func pick(_ item: ClipItem) {
        close()
        state.copy(item, paste: true)
    }

    private func makePanel() -> QuickPanel {
        let p = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 440),
                           styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                           backing: .buffered, defer: true)
        p.title = "ClipMom"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
        p.onClose = { [weak self] in self?.close() }
        let view = QuickPanelView(model: model, controller: self)
            .environment(state)
            .environment(\.locale, Locale(identifier: "ru_RU"))
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []  // размер задаёт панель, а не SwiftUI
        p.contentView = host
        return p
    }

    // ↑/↓, ↩, Esc, ⌘1…⌘9 — перехватываем до текстового поля.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let p = self.panel, e.window === p else { return e }
            return self.handle(e) ? nil : e
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        let list = results()
        let cmd = e.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        switch Int(e.keyCode) {
        case 125:  // ↓
            if !list.isEmpty { model.index = min(model.index + 1, list.count - 1) }
            return true
        case 126:  // ↑
            model.index = max(model.index - 1, 0)
            return true
        case 36, 76:  // ↩
            if model.index < list.count { pick(list[model.index]) }
            return true
        case 53:  // Esc
            close()
            return true
        default:
            if cmd, let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {
                if n - 1 < list.count { pick(list[n - 1]) }
                return true
            }
            return false
        }
    }
}

struct QuickPanelView: View {
    @Environment(AppState.self) private var state
    @Bindable var model: QuickModel
    let controller: QuickPanelController
    @FocusState private var focused: Bool

    var body: some View {
        let list = controller.results()
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск в истории", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onChange(of: model.query) { model.index = 0 }
                Text("⇧⌘V").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Divider()
            if list.isEmpty {
                EmptyStateView(icon: "list.clipboard", title: state.items.isEmpty ? "История пуста" : "Ничего не нашлось",
                               text: state.items.isEmpty ? "Скопируйте что-нибудь — оно появится здесь." : "Попробуйте другое слово.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                                QuickRow(item: item, number: i < 9 ? i + 1 : nil, selected: i == model.index)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { controller.pick(item) }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.index) {
                        if model.index < list.count { proxy.scrollTo(list[model.index].id) }
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "выбрать")
                hint("↩", state.prefs.autoPaste && AutoPaste.trusted ? "вставить" : "скопировать")
                hint("⌘1–9", "быстро")
                hint("esc", "закрыть")
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea()
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(text).foregroundStyle(.secondary)
        }
    }
}

struct QuickRow: View {
    let item: ClipItem
    let number: Int?
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ClipIcon(item: item, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                    .foregroundStyle(selected ? .white : .primary)
                Text([item.sourceName, Fmt.ago(item.date)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill").font(.caption)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Brand.blue))
            }
            if let n = number {
                Text("⌘\(n)").font(.caption.monospaced())
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.gradient)
            }
        }
    }
}

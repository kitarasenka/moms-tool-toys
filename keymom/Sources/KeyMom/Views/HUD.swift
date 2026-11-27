import AppKit
import SwiftUI

struct HUDMessage: Equatable {
    enum Style { case layout, caps, warning, success }
    var title: String
    var flag: String
    var subtitle: String?
    var style: Style
}

/// Плашка у курсора мыши: не забирает фокус, не ловит щелчки, видна поверх всех окон и на всех столах.
@MainActor
final class HUD {
    private let panel: NSPanel
    private let host = NSHostingView(rootView: HUDView(message: HUDMessage(title: "", flag: "", style: .layout)))
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }

    /// duration == nil — висит, пока не скроют.
    func show(_ m: HUDMessage, duration: TimeInterval?) {
        hideWork?.cancel()
        host.rootView = HUDView(message: m)
        let size = host.fittingSize
        panel.setContentSize(size)
        follow()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if let duration {
            let w = DispatchWorkItem { [weak self] in self?.fadeOut() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: w)
        }
    }

    /// Поставить у курсора (справа снизу; у края экрана — с другой стороны).
    func follow() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var x = mouse.x + 18, y = mouse.y - 22 - size.height
        if x + size.width > vf.maxX { x = mouse.x - 18 - size.width }
        if y < vf.minY { y = mouse.y + 22 }
        x = min(max(x, vf.minX), vf.maxX - size.width)
        y = min(max(y, vf.minY), vf.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            }
        })
    }
}

struct HUDView: View {
    let message: HUDMessage

    var body: some View {
        HStack(spacing: 10) {
            Text(message.flag).font(.system(size: 26))
            VStack(alignment: .leading, spacing: 1) {
                Text(message.title).font(.system(size: 20, weight: .bold, design: .rounded))
                if let s = message.subtitle {
                    // Длинную подсказку переносим на вторую строку, а не обрезаем.
                    Text(s).font(.system(size: 12)).opacity(0.9).lineLimit(3)
                        .frame(width: s.count > 34 ? 250 : nil, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .padding(12)  // место для тени
        .fixedSize()
    }

    private var background: AnyShapeStyle {
        switch message.style {
        case .layout: AnyShapeStyle(Brand.gradient)
        case .caps: AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.2), .orange],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
        case .warning: AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.25), .red],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
        case .success: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.3, green: 0.82, blue: 0.45), Color(red: 0.12, green: 0.6, blue: 0.35)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}

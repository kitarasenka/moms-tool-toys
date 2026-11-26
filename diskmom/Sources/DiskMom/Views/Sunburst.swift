import SwiftUI

// MARK: - Раскладка

struct SunSegment: Identifiable {
    let id: Int
    /// nil — «Остальное» (мелочь, слитая в один сектор).
    let node: FSNode?
    let parent: FSNode
    let ring: Int
    /// Доли полного круга, 0 — «12 часов», по часовой стрелке.
    let start: Double
    let end: Double
    /// Номер ребёнка первого кольца, от которого берётся цвет; -1 — серый.
    let colorIndex: Int
    /// Номер среди соседей — соседние сектора внешних колец чуть различаются оттенком.
    let shade: Int
    let size: Int64
    let otherCount: Int

    var label: String { node?.displayName ?? "Остальное (\(otherCount.formatted()))" }
    var mid: Double { (start + end) / 2 }
}

enum Sunburst {
    static let rings = 3
    /// Сектор уже этого (≈1,4°) сливается в «Остальное».
    static let minFraction = 0.004

    static func layout(_ focus: FSNode) -> [SunSegment] {
        var out: [SunSegment] = []
        guard focus.size > 0 else { return out }
        func place(_ node: FSNode, ring: Int, start: Double, span: Double, color: Int) {
            guard ring <= rings, node.size > 0, !node.children.isEmpty else { return }
            var pos = start
            var otherSize: Int64 = 0, otherCount = 0
            for (i, c) in node.children.enumerated() where c.size > 0 {
                let w = span * Double(c.size) / Double(node.size)
                if w < minFraction { otherSize += c.size; otherCount += 1; continue }
                let ci = ring == 1 ? (isGray(c) ? -1 : i) : (isGray(c) ? -1 : color)
                out.append(SunSegment(id: out.count, node: c, parent: node, ring: ring, start: pos, end: pos + w,
                                      colorIndex: ci, shade: i, size: c.size, otherCount: 0))
                if c.kind == .folder { place(c, ring: ring + 1, start: pos, span: w, color: ci) }
                pos += w
            }
            if otherSize > 0 {
                let w = span * Double(otherSize) / Double(node.size)
                out.append(SunSegment(id: out.count, node: nil, parent: node, ring: ring, start: pos, end: pos + w,
                                      colorIndex: -1, shade: 0, size: otherSize, otherCount: otherCount))
            }
        }
        place(focus, ring: 1, start: 0, span: 1, color: -1)
        return out
    }

    private static func isGray(_ n: FSNode) -> Bool { n.kind == .smallFiles || n.kind == .locked || n.kind == .cloud }

    private static let hues: [Double] = [0.60, 0.52, 0.45, 0.36, 0.24, 0.13, 0.07, 0.98, 0.90, 0.77]

    static func color(_ index: Int, ring: Int = 1, shade: Int = 0) -> Color {
        if index < 0 { return Color(white: ring == 1 ? 0.62 : 0.72) }
        var h = hues[index % hues.count]
        let r = min(max(ring - 1, 0), 2)
        var sat = [0.78, 0.56, 0.40][r]
        var bri = [0.90, 0.95, 0.99][r]
        if ring > 1 {
            let k = Double(shade % 4)
            h += (k - 1.5) * 0.012
            sat += (k - 1.5) * 0.07
            bri -= Double(shade % 2) * 0.06
        }
        return Color(hue: h.truncatingRemainder(dividingBy: 1) + (h < 0 ? 1 : 0), saturation: sat, brightness: bri)
    }
}

// MARK: - Диаграмма

struct SunburstView: View {
    let segments: [SunSegment]
    let focus: FSNode
    let selected: FSNode?
    @Binding var hovered: SunSegment?
    @Binding var hoveringCenter: Bool
    var onTap: (SunSegment?) -> Void

    private struct Geo {
        var center: CGPoint
        var inner: CGFloat
        var ring: CGFloat
        var outer: CGFloat { inner + ring * CGFloat(Sunburst.rings) }
    }

    private func geometry(_ size: CGSize) -> Geo {
        let r = max(40, min(size.width, size.height) / 2 - 12)
        let inner = r * 0.30
        return Geo(center: CGPoint(x: size.width / 2, y: size.height / 2), inner: inner,
                   ring: (r - inner) / CGFloat(Sunburst.rings))
    }

    var body: some View {
        GeometryReader { proxy in
            let g = geometry(proxy.size)
            ZStack {
                Canvas { ctx, _ in draw(ctx, g) }
                centerLabel
                    .frame(width: g.inner * 1.7)
                    .position(g.center)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    let h = hit(p, g)
                    hoveringCenter = h.center
                    if hovered?.id != h.segment?.id || hovered?.parent !== h.segment?.parent { hovered = h.segment }
                case .ended:
                    hovered = nil
                    hoveringCenter = false
                }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                let h = hit(p, g)
                if h.center { onTap(nil) } else if let s = h.segment { onTap(s) }
            }
        }
    }

    private var centerLabel: some View {
        VStack(spacing: 3) {
            if let h = hovered {
                Text(h.label).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                Text(Fmt.bytes(h.size)).font(.title3.weight(.semibold)).monospacedDigit()
                Text(Fmt.percent(Double(h.size) / Double(max(focus.size, 1))) + " от «\(focus.name)»")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if hoveringCenter, focus.parent != nil {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)).foregroundStyle(Brand.gradient)
                Text("Наверх").font(.headline)
            } else {
                Text(focus.displayName).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                Text(Fmt.bytes(focus.size)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Text(Fmt.files(focus.fileCount)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ g: Geo) {
        // Середина
        let centerRect = CGRect(x: g.center.x - g.inner + 3, y: g.center.y - g.inner + 3,
                                width: (g.inner - 3) * 2, height: (g.inner - 3) * 2)
        ctx.fill(Path(ellipseIn: centerRect), with: .color(Brand.blue.opacity(hoveringCenter && focus.parent != nil ? 0.16 : 0.07)))

        if segments.isEmpty {
            let r = g.outer
            let ring = Path(ellipseIn: CGRect(x: g.center.x - r, y: g.center.y - r, width: r * 2, height: r * 2))
            ctx.stroke(ring, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            return
        }

        for s in segments {
            let path = arc(s, g)
            let hot = hovered.map { $0.id == s.id } ?? false
            let isSel = selected != nil && s.node === selected
            var color = Sunburst.color(s.colorIndex, ring: s.ring, shade: s.shade)
            if hot { color = color.opacity(0.75) }
            ctx.fill(path, with: .color(color))
            ctx.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1)
            if isSel { ctx.stroke(path, with: .color(.primary), lineWidth: 2.5) }
        }

        // Подписи крупных секторов первого кольца
        for s in segments where s.ring == 1 && (s.end - s.start) > 0.055 {
            let angle = (s.mid * 2 * .pi) - .pi / 2
            let r = g.inner + g.ring * 0.5
            let p = CGPoint(x: g.center.x + cos(angle) * r, y: g.center.y + sin(angle) * r)
            let name = s.label.count > 14 ? String(s.label.prefix(13)) + "…" : s.label
            var c = ctx
            c.addFilter(.shadow(color: .black.opacity(0.55), radius: 1.5))
            c.draw(Text(name).font(.system(size: 10, weight: .semibold)).foregroundColor(.white), at: p)
        }
    }

    private func arc(_ s: SunSegment, _ g: Geo) -> Path {
        let inner = g.inner + g.ring * CGFloat(s.ring - 1)
        let outer = inner + g.ring
        let a0 = Angle(radians: s.start * 2 * .pi - .pi / 2)
        let a1 = Angle(radians: s.end * 2 * .pi - .pi / 2)
        var p = Path()
        p.addArc(center: g.center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: g.center, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }

    private func hit(_ p: CGPoint, _ g: Geo) -> (segment: SunSegment?, center: Bool) {
        let dx = p.x - g.center.x, dy = p.y - g.center.y
        let d = (dx * dx + dy * dy).squareRoot()
        if d < g.inner { return (nil, true) }
        let ring = Int((d - g.inner) / g.ring) + 1
        guard ring <= Sunburst.rings else { return (nil, false) }
        var a = atan2(dy, dx) + .pi / 2
        if a < 0 { a += 2 * .pi }
        let f = Double(a / (2 * .pi))
        return (segments.first { $0.ring == ring && $0.start <= f && f < $0.end }, false)
    }
}

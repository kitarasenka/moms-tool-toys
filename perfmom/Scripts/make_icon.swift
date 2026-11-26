// Рисует иконку приложения (1024×1024) в духе macOS: «сквиркл», тёмный градиент, график нагрузки.
import AppKit

let out = CommandLine.arguments[1]
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

// Тень под иконкой
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()

NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.18, blue: 0.24, alpha: 1),
                    NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)])!
    .draw(in: squircle, angle: -90)

squircle.addClip()

// Сетка
NSColor.white.withAlphaComponent(0.07).setStroke()
for i in 1..<6 {
    let y = body.minY + CGFloat(i) * body.height / 6
    let line = NSBezierPath()
    line.move(to: NSPoint(x: body.minX, y: y))
    line.line(to: NSPoint(x: body.maxX, y: y))
    line.lineWidth = 3
    line.stroke()
}

// График
let values: [CGFloat] = [0.30, 0.34, 0.28, 0.42, 0.38, 0.55, 0.47, 0.72, 0.58, 0.64, 0.50, 0.80, 0.62, 0.68]
let left = body.minX + 70, right = body.maxX - 70, bottom = body.minY + 170, top = body.maxY - 170
func point(_ i: Int) -> NSPoint {
    NSPoint(x: left + (right - left) * CGFloat(i) / CGFloat(values.count - 1),
            y: bottom + (top - bottom) * values[i])
}
let curve = NSBezierPath()
curve.move(to: point(0))
for i in 1..<values.count {
    let p0 = point(i - 1), p1 = point(i)
    let mx = (p0.x + p1.x) / 2
    curve.curve(to: p1, controlPoint1: NSPoint(x: mx, y: p0.y), controlPoint2: NSPoint(x: mx, y: p1.y))
}
let area = curve.copy() as! NSBezierPath
area.line(to: NSPoint(x: right, y: body.minY))
area.line(to: NSPoint(x: left, y: body.minY))
area.close()
NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.85, blue: 0.55, alpha: 0.55),
                    NSColor(srgbRed: 0.20, green: 0.85, blue: 0.55, alpha: 0.0)])!
    .draw(in: area, angle: -90)

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 24, color: NSColor(srgbRed: 0.3, green: 1, blue: 0.6, alpha: 0.8).cgColor)
NSColor(srgbRed: 0.35, green: 0.95, blue: 0.62, alpha: 1).setStroke()
curve.lineWidth = 22
curve.lineCapStyle = .round
curve.lineJoinStyle = .round
curve.stroke()
ctx.restoreGState()

// Точка «текущего» значения
let last = point(values.count - 1)
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: last.x - 22, y: last.y - 22, width: 44, height: 44)).fill()

// Блик сверху
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

// Рисует иконку приложения: значок Wi-Fi на сине-зелёном скруглённом квадрате.
// swift icon.swift <out.png> — PNG 1024×1024, из него install.sh делает .icns.
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let inset = size * 0.1
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.50, blue: 0.98, alpha: 1),
           ending: NSColor(srgbRed: 0.10, green: 0.78, blue: 0.62, alpha: 1))!.draw(in: shape, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
  .applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
  let s = sym.size
  sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + size * 0.02, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

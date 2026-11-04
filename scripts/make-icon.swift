import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let unit = CGFloat(pixels) / 1024
        let inset = 70 * unit
        let rect = NSRect(x: inset, y: inset, width: CGFloat(pixels) - 2 * inset, height: CGFloat(pixels) - 2 * inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: 195 * unit, yRadius: 195 * unit)
        NSColor(calibratedRed: 0.14, green: 0.41, blue: 0.86, alpha: 1).setFill()
        path.fill()
        let symbol = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 570 * unit, weight: .regular))!
        let symbolRect = NSRect(x: 260 * unit, y: 205 * unit, width: 504 * unit, height: 614 * unit)
        let tintedSymbol = NSImage(size: symbolRect.size)
        tintedSymbol.lockFocus()
        let localRect = NSRect(origin: .zero, size: symbolRect.size)
        symbol.draw(in: localRect)
        NSColor.white.setFill()
        localRect.fill(using: .sourceAtop)
        tintedSymbol.unlockFocus()
        tintedSymbol.draw(in: symbolRect)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

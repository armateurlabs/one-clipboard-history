import AppKit

// Original Armateur Labs artwork made of geometric paths. No SF Symbols,
// system images, downloaded assets or third-party artwork are used here.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = destination.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rounded(_ rect: NSRect, _ radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    cg.setAllowsAntialiasing(true)

    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 192, yRadius: 192)
    NSGradient(colors: [NSColor(srgbRed: 0.12, green: 0.26, blue: 0.69, alpha: 1),
                        NSColor(srgbRed: 0.21, green: 0.58, blue: 0.96, alpha: 1)])!.draw(in: tile, angle: 75)

    // Offset sheets suggest a history; the front sheet is the active copy.
    rounded(NSRect(x: 346, y: 226, width: 430, height: 580), 50,
            color: NSColor.white.withAlphaComponent(0.22))
    rounded(NSRect(x: 302, y: 202, width: 430, height: 580), 50,
            color: NSColor.white.withAlphaComponent(0.45))
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 32,
                 color: NSColor(srgbRed: 0.02, green: 0.09, blue: 0.32, alpha: 0.25).cgColor)
    let paper = NSBezierPath(roundedRect: NSRect(x: 244, y: 180, width: 430, height: 580), xRadius: 50, yRadius: 50)
    NSGradient(colors: [NSColor(srgbRed: 0.84, green: 0.94, blue: 1, alpha: 1), .white])!.draw(in: paper, angle: 90)
    cg.restoreGState()

    rounded(NSRect(x: 348, y: 716, width: 222, height: 92), 31,
            color: NSColor(srgbRed: 0.04, green: 0.25, blue: 0.56, alpha: 1))
    rounded(NSRect(x: 379, y: 756, width: 160, height: 12), 6,
            color: NSColor(srgbRed: 0.43, green: 0.77, blue: 1, alpha: 1))
    let one: NSString = "1"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 255, weight: .bold),
        .foregroundColor: NSColor(srgbRed: 0.10, green: 0.37, blue: 0.77, alpha: 1)
    ]
    let oneSize = one.size(withAttributes: attributes)
    one.draw(at: NSPoint(x: 459 - oneSize.width / 2, y: 380), withAttributes: attributes)
    for (index, width) in [CGFloat(246), 186, 130].enumerated() {
        rounded(NSRect(x: 336, y: 338 - CGFloat(index) * 49, width: width, height: 18), 9,
                color: NSColor(srgbRed: 0.17, green: 0.43, blue: 0.74, alpha: index == 0 ? 0.65 : 0.28))
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try renderIcon(pixels: size * scale).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

import Foundation

/// AppKit screen coordinates grow upward. Only placement is interpreted here;
/// the saved frame and the user's selected quadrant remain independent.
enum WindowPlacement {
    static func frame(
        around pointer: NSPoint, size: NSSize, quadrant: PointerQuadrant,
        visibleFrame: NSRect, minimumSize: NSSize = .init(width: 280, height: 280),
        gap: CGFloat = 12
    ) -> NSRect {
        let boundedSize = clamp(NSRect(origin: .zero, size: size), to: visibleFrame, minimumSize: minimumSize).size
        let point = NSPoint(x: pointer.x.isFinite ? pointer.x : visibleFrame.midX,
                            y: pointer.y.isFinite ? pointer.y : visibleFrame.midY)
        let spacing = gap.isFinite ? max(0, gap) : 12
        let origin: NSPoint
        switch quadrant {
        case .topLeft:
            origin = .init(x: point.x - spacing - boundedSize.width, y: point.y + spacing)
        case .topRight:
            origin = .init(x: point.x + spacing, y: point.y + spacing)
        case .bottomLeft:
            origin = .init(x: point.x - spacing - boundedSize.width, y: point.y - spacing - boundedSize.height)
        case .bottomRight:
            origin = .init(x: point.x + spacing, y: point.y - spacing - boundedSize.height)
        }
        return clamp(NSRect(origin: origin, size: boundedSize), to: visibleFrame, minimumSize: minimumSize)
    }

    static func clamp(_ frame: NSRect, to visibleFrame: NSRect, minimumSize: NSSize) -> NSRect {
        let minWidth = minimumSize.width.isFinite ? max(1, minimumSize.width) : 280
        let minHeight = minimumSize.height.isFinite ? max(1, minimumSize.height) : 280
        let width = min(max(frame.width.isFinite ? frame.width : minWidth, minWidth), visibleFrame.width)
        let height = min(max(frame.height.isFinite ? frame.height : minHeight, minHeight), visibleFrame.height)
        let x = frame.origin.x.isFinite ? frame.origin.x : visibleFrame.midX - width / 2
        let y = frame.origin.y.isFinite ? frame.origin.y : visibleFrame.midY - height / 2
        return NSRect(
            x: min(max(x, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(y, visibleFrame.minY), visibleFrame.maxY - height),
            width: width, height: height
        )
    }
}

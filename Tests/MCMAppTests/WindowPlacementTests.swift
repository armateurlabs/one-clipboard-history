import AppKit
import Testing
@testable import MCMApp

@Suite("Pointer window placement")
@MainActor
struct WindowPlacementTests {
    @Test func quadrantsUseAppKitCoordinatesAndKeepACursorGap() {
        let pointer = NSPoint(x: 1_000, y: 1_000)
        let size = NSSize(width: 320, height: 400)
        let visible = NSRect(x: 0, y: 0, width: 3_000, height: 3_000)
        let expected: [PointerQuadrant: NSPoint] = [
            .topLeft: .init(x: 668, y: 1_012),
            .topRight: .init(x: 1_012, y: 1_012),
            .bottomLeft: .init(x: 668, y: 588),
            .bottomRight: .init(x: 1_012, y: 588)
        ]

        for quadrant in PointerQuadrant.allCases {
            let frame = WindowPlacement.frame(around: pointer, size: size, quadrant: quadrant, visibleFrame: visible)
            #expect(frame.origin == expected[quadrant])
            #expect(frame.size == size)
        }
    }

    @Test func everyQuadrantStaysVisibleAtEachScreenCorner() {
        let visible = NSRect(x: -1_920, y: -200, width: 1_920, height: 1_080)
        let corners = [
            NSPoint(x: visible.minX, y: visible.minY),
            NSPoint(x: visible.minX, y: visible.maxY),
            NSPoint(x: visible.maxX, y: visible.minY),
            NSPoint(x: visible.maxX, y: visible.maxY)
        ]

        for pointer in corners {
            for quadrant in PointerQuadrant.allCases {
                let frame = WindowPlacement.frame(
                    around: pointer, size: .init(width: 520, height: 640),
                    quadrant: quadrant, visibleFrame: visible
                )
                expectContained(frame, in: visible)
                #expect(frame.size == NSSize(width: 520, height: 640))
            }
        }
    }

    @Test func savedWidthOf280PointsIsAcceptedWithoutExpansion() {
        let saved = NSRect(x: 50, y: 60, width: 280, height: 520)
        let result = WindowPlacement.clamp(
            saved, to: .init(x: 0, y: 0, width: 1_440, height: 900),
            minimumSize: .init(width: 280, height: 280)
        )
        #expect(result == saved)
    }

    @Test func minimumSizeAndSmallScreensAreHandledTogether() {
        let visible = NSRect(x: -400, y: 100, width: 240, height: 180)
        let result = WindowPlacement.frame(
            around: .init(x: -250, y: 170), size: .init(width: 520, height: 640),
            quadrant: .bottomRight, visibleFrame: visible
        )
        #expect(result == visible)

        let regularScreen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let expanded = WindowPlacement.clamp(
            .init(x: 100, y: 100, width: 200, height: 150), to: regularScreen,
            minimumSize: .init(width: 280, height: 280)
        )
        #expect(expanded.size == NSSize(width: 280, height: 280))
        expectContained(expanded, in: regularScreen)
    }

    @Test func nonFiniteSavedFramesAreSanitized() {
        let visible = NSRect(x: -1_200, y: -300, width: 1_200, height: 900)
        let frames = [
            NSRect(x: CGFloat.nan, y: CGFloat.infinity, width: CGFloat.nan, height: -CGFloat.infinity),
            NSRect(x: -CGFloat.infinity, y: CGFloat.nan, width: CGFloat.infinity, height: -10),
            NSRect(x: 100_000, y: -100_000, width: 1, height: 1)
        ]

        for frame in frames {
            let result = WindowPlacement.clamp(frame, to: visible, minimumSize: .init(width: 280, height: 280))
            expectContained(result, in: visible)
            #expect(result.width >= 280)
            #expect(result.height >= 280)
        }
    }

    @Test func nonFinitePointerAndSizeStillProduceAnAccessibleWindow() {
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        for quadrant in PointerQuadrant.allCases {
            let frame = WindowPlacement.frame(
                around: .init(x: CGFloat.nan, y: CGFloat.infinity),
                size: .init(width: CGFloat.nan, height: CGFloat.infinity),
                quadrant: quadrant, visibleFrame: visible
            )
            expectContained(frame, in: visible)
            #expect(frame.width >= 280)
            #expect(frame.height >= 280)
        }
    }

    private func expectContained(_ frame: NSRect, in visible: NSRect) {
        #expect(frame.origin.x.isFinite)
        #expect(frame.origin.y.isFinite)
        #expect(frame.width.isFinite)
        #expect(frame.height.isFinite)
        #expect(frame.minX >= visible.minX)
        #expect(frame.minY >= visible.minY)
        #expect(frame.maxX <= visible.maxX)
        #expect(frame.maxY <= visible.maxY)
    }
}

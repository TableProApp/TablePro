import CoreGraphics
import Testing

@testable import TablePro

@Suite("ERDiagramScrollTranslator")
struct ERDiagramScrollTranslatorTests {
    @Test("precise deltas pan point for point")
    func preciseDeltasPanUnscaled() {
        let action = ERDiagramScrollTranslator.action(
            scrollingDeltaX: 12,
            scrollingDeltaY: -8,
            hasPreciseScrollingDeltas: true,
            isZoomModifierActive: false,
            currentOffset: CGPoint(x: 100, y: 50),
            currentMagnification: 1.0
        )
        #expect(action == .pan(CGPoint(x: 112, y: 42)))
    }

    @Test("line deltas pan with the wheel multiplier")
    func lineDeltasPanScaled() {
        let action = ERDiagramScrollTranslator.action(
            scrollingDeltaX: 2,
            scrollingDeltaY: 3,
            hasPreciseScrollingDeltas: false,
            isZoomModifierActive: false,
            currentOffset: .zero,
            currentMagnification: 1.0
        )
        #expect(action == .pan(CGPoint(x: 20, y: 30)))
    }

    @Test("zoom modifier zooms from the vertical delta")
    func zoomModifierZooms() {
        let action = ERDiagramScrollTranslator.action(
            scrollingDeltaX: 5,
            scrollingDeltaY: 50,
            hasPreciseScrollingDeltas: true,
            isZoomModifierActive: true,
            currentOffset: .zero,
            currentMagnification: 1.0
        )
        guard case .zoom(let magnification) = action else {
            Issue.record("expected zoom, got \(action)")
            return
        }
        #expect(abs(magnification - 1.5) < 0.0001)
    }

    @Test("zero deltas keep the offset")
    func zeroDeltasKeepOffset() {
        let offset = CGPoint(x: 33, y: -7)
        let action = ERDiagramScrollTranslator.action(
            scrollingDeltaX: 0,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            isZoomModifierActive: false,
            currentOffset: offset,
            currentMagnification: 1.0
        )
        #expect(action == .pan(offset))
    }

    @Test("negative deltas invert both axes")
    func negativeDeltasInvert() {
        let action = ERDiagramScrollTranslator.action(
            scrollingDeltaX: -4,
            scrollingDeltaY: -6,
            hasPreciseScrollingDeltas: false,
            isZoomModifierActive: false,
            currentOffset: CGPoint(x: 100, y: 100),
            currentMagnification: 1.0
        )
        #expect(action == .pan(CGPoint(x: 60, y: 40)))
    }
}

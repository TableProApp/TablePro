import CoreGraphics
import Testing

@testable import TablePro

@Suite("Query Plan Diagram Zoom")
struct QueryPlanDiagramZoomTests {
    @Test("pinch scales from the gesture start")
    func scalesFromGestureStart() {
        let magnification = QueryPlanDiagramZoom.scaled(from: 1.5, by: 1.2)
        #expect(abs(magnification - 1.8) < 0.0001)
    }

    @Test("pinch clamps to the supported range")
    func clampsPinchRange() {
        #expect(QueryPlanDiagramZoom.scaled(from: 2.0, by: 2.0) == 3.0)
        #expect(QueryPlanDiagramZoom.scaled(from: 0.5, by: 0.1) == 0.25)
    }

    @Test("invalid pinch values preserve the current zoom")
    func rejectsInvalidPinchValues() {
        #expect(QueryPlanDiagramZoom.scaled(from: 1.5, by: .nan) == 1.5)
        #expect(QueryPlanDiagramZoom.scaled(from: 1.5, by: .infinity) == 1.5)
        #expect(QueryPlanDiagramZoom.scaled(from: 1.5, by: 0) == 1.5)
        #expect(QueryPlanDiagramZoom.scaled(from: 1.5, by: -1) == 1.5)
    }

    @Test("button zoom values use the same bounds")
    func clampsButtonZoomRange() {
        #expect(QueryPlanDiagramZoom.clamped(-10) == 0.25)
        #expect(QueryPlanDiagramZoom.clamped(10) == 3.0)
        #expect(QueryPlanDiagramZoom.clamped(.nan) == 1.0)
    }
}

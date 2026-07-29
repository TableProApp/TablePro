import AppKit
import SwiftUI
import Testing

@testable import TablePro

@Suite("ERDiagramCanvasContainerView scroll routing")
@MainActor
struct ERDiagramCanvasContainerViewTests {
    private func makeContainer() -> (ERDiagramCanvasContainerView<Color>, ERDiagramViewModel) {
        let viewModel = ERDiagramViewModel(connectionId: UUID(), schemaKey: "test")
        let view = ERDiagramCanvasContainerView(rootView: Color.clear, viewModel: viewModel)
        return (view, viewModel)
    }

    private func makeScrollEvent(
        deltaX: Int32,
        deltaY: Int32,
        units: CGScrollEventUnit,
        flags: CGEventFlags = []
    ) -> NSEvent? {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: units,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return nil }
        cgEvent.flags = flags
        return NSEvent(cgEvent: cgEvent)
    }

    @Test("trackpad scroll pans the canvas by the event deltas")
    func trackpadScrollPans() throws {
        let (view, viewModel) = makeContainer()
        let event = try #require(makeScrollEvent(deltaX: 12, deltaY: -8, units: .pixel))
        try #require(event.hasPreciseScrollingDeltas)
        try #require(event.scrollingDeltaY != 0)

        view.scrollWheel(with: event)

        #expect(viewModel.canvasOffset == CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
    }

    @Test("mouse wheel scroll pans with the line multiplier")
    func mouseWheelScrollPans() throws {
        let (view, viewModel) = makeContainer()
        let event = try #require(makeScrollEvent(deltaX: 0, deltaY: 3, units: .line))
        try #require(!event.hasPreciseScrollingDeltas)
        try #require(event.scrollingDeltaY != 0)

        view.scrollWheel(with: event)

        #expect(viewModel.canvasOffset.y == event.scrollingDeltaY * 10)
    }

    @Test("command scroll zooms through the view model")
    func commandScrollZooms() throws {
        let (view, viewModel) = makeContainer()
        let event = try #require(makeScrollEvent(deltaX: 0, deltaY: 40, units: .pixel, flags: .maskCommand))
        try #require(event.scrollingDeltaY != 0)

        view.scrollWheel(with: event)

        let expected = 1.0 + event.scrollingDeltaY * 0.01
        #expect(abs(viewModel.magnification - expected) < 0.0001)
        #expect(viewModel.canvasOffset == .zero)
    }

    @Test("command scroll zoom clamps to the maximum magnification")
    func commandScrollZoomClamps() throws {
        let (view, viewModel) = makeContainer()
        let event = try #require(makeScrollEvent(deltaX: 0, deltaY: 400, units: .pixel, flags: .maskCommand))
        try #require(event.scrollingDeltaY >= 200)

        view.scrollWheel(with: event)

        #expect(viewModel.magnification == 3.0)
    }
}

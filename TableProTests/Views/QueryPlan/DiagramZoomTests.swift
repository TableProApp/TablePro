//
//  DiagramZoomTests.swift
//  TableProTests
//
//  Tests for the zoom bounds shared by the ER and query plan diagrams.
//

import CoreGraphics
@testable import TablePro
import Testing

@Suite("Diagram Zoom")
struct DiagramZoomTests {
    @Test("pinch scales from the gesture start")
    func scalesFromGestureStart() {
        let magnification = DiagramZoom.scaled(from: 1.5, by: 1.2)
        #expect(abs(magnification - 1.8) < 0.0001)
    }

    @Test("pinch clamps to the supported range")
    func clampsPinchRange() {
        #expect(DiagramZoom.scaled(from: 2.0, by: 2.0) == 3.0)
        #expect(DiagramZoom.scaled(from: 0.5, by: 0.1) == 0.25)
    }

    @Test("invalid pinch values preserve the current zoom")
    func rejectsInvalidPinchValues() {
        #expect(DiagramZoom.scaled(from: 1.5, by: .nan) == 1.5)
        #expect(DiagramZoom.scaled(from: 1.5, by: .infinity) == 1.5)
        #expect(DiagramZoom.scaled(from: 1.5, by: 0) == 1.5)
        #expect(DiagramZoom.scaled(from: 1.5, by: -1) == 1.5)
    }

    @Test("button zoom values use the same bounds")
    func clampsButtonZoomRange() {
        #expect(DiagramZoom.clamped(-10) == DiagramZoom.minimum)
        #expect(DiagramZoom.clamped(10) == DiagramZoom.maximum)
        #expect(DiagramZoom.clamped(.nan) == 1.0)
    }

    @Test("a released pinch resolves to the gesture's final scale")
    func resolvesEndedPinch() {
        #expect(DiagramZoom.scaled(from: 1.0, by: 2.5) == 2.5)
        #expect(DiagramZoom.scaled(from: 2.5, by: 1.0) == 2.5)
    }
}

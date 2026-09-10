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
        #expect(DiagramZoom.scaled(from: 2.0, by: 2.0) == DiagramZoom.maximum)
        #expect(DiagramZoom.scaled(from: 0.5, by: 0.001) == DiagramZoom.minimum)
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

    @Test("a button step lands on the next rung, not a fixed distance away")
    func stepsAlongTheLadder() {
        #expect(DiagramZoom.stepUp(from: 1.0) == 1.5)
        #expect(DiagramZoom.stepDown(from: 1.0) == 0.75)
        #expect(DiagramZoom.stepUp(from: 0.41) == 0.5)
        #expect(DiagramZoom.stepDown(from: 0.41) == 0.33)
    }

    @Test("a step from a rung leaves that rung")
    func stepsOffItsOwnRung() {
        for rung in DiagramZoom.ladder.dropLast() {
            #expect(DiagramZoom.stepUp(from: rung) > rung)
        }
        for rung in DiagramZoom.ladder.dropFirst() {
            #expect(DiagramZoom.stepDown(from: rung) < rung)
        }
    }

    @Test("a step stops at the ends instead of wrapping or standing still")
    func stepsClampAtTheEnds() {
        #expect(DiagramZoom.stepUp(from: DiagramZoom.maximum) == DiagramZoom.maximum)
        #expect(DiagramZoom.stepDown(from: DiagramZoom.minimum) == DiagramZoom.minimum)
        #expect(!DiagramZoom.canStepUp(from: DiagramZoom.maximum))
        #expect(!DiagramZoom.canStepDown(from: DiagramZoom.minimum))
        #expect(DiagramZoom.canStepUp(from: 1.0))
        #expect(DiagramZoom.canStepDown(from: 1.0))
    }

    @Test("the floor sits below the ladder so Fit can reach a diagram the buttons cannot")
    func floorLeavesRoomForFit() {
        #expect(DiagramZoom.minimum < DiagramZoom.ladder[0])
        #expect(DiagramZoom.clamped(0.02) == 0.02)
        #expect(DiagramZoom.clamped(0.001) == DiagramZoom.minimum)
    }
}

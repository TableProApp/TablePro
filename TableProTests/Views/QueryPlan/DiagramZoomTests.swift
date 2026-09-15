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

    @Test("a step never passes either end of the zoom range")
    func stepsClampAtTheEnds() {
        #expect(DiagramZoom.stepUp(from: DiagramZoom.maximum) == DiagramZoom.maximum)
        #expect(DiagramZoom.stepDown(from: DiagramZoom.minimum) == DiagramZoom.minimum)
        #expect(!DiagramZoom.canStepUp(from: DiagramZoom.maximum))
        #expect(!DiagramZoom.canStepDown(from: DiagramZoom.minimum))
        #expect(DiagramZoom.canStepUp(from: 1.0))
        #expect(DiagramZoom.canStepDown(from: 1.0))
    }

    @Test("zoom out stops at the ladder's floor instead of dropping to the minimum")
    func stepDownStopsAtTheLadderFloor() {
        let floor = DiagramZoom.ladder[0]
        #expect(DiagramZoom.stepDown(from: floor) == floor)
        #expect(!DiagramZoom.canStepDown(from: floor))
        #expect(!DiagramZoom.canStepDown(from: floor + 0.0001))
        #expect(DiagramZoom.canStepUp(from: floor))
    }

    @Test("below the floor, zoom out has nowhere to go and zoom in climbs back onto the ladder")
    func stepsFromBelowTheFloor() {
        let fitted: CGFloat = 0.03
        #expect(DiagramZoom.stepDown(from: fitted) == fitted)
        #expect(!DiagramZoom.canStepDown(from: fitted))
        #expect(DiagramZoom.stepUp(from: fitted) == DiagramZoom.ladder[0])
        #expect(DiagramZoom.canStepUp(from: fitted))
        #expect(DiagramZoom.stepUp(from: DiagramZoom.minimum) == DiagramZoom.ladder[0])
    }

    @Test("between the floor and the next rung, zoom out lands on the floor")
    func stepsDownOntoTheFloor() {
        #expect(DiagramZoom.canStepDown(from: 0.07))
        #expect(DiagramZoom.stepDown(from: 0.07) == DiagramZoom.ladder[0])
    }

    static let sweep: [CGFloat] = [DiagramZoom.minimum, 0.02, 0.03, 0.0499, 0.07, 2.9995, DiagramZoom.maximum]
        + DiagramZoom.ladder.flatMap { [$0 - 1e-7, $0, $0 + 1e-7] }

    /// The availability checks and the steps share one definition of the next rung, so a button can
    /// never be enabled for a step that goes nowhere or disabled for one that would move.
    @Test("a step lands on a rung or stays put, and is available exactly when it moves", arguments: sweep)
    func stepsAndTheirAvailabilityAgree(value: CGFloat) {
        let current = DiagramZoom.clamped(value)
        let down = DiagramZoom.stepDown(from: value)
        let up = DiagramZoom.stepUp(from: value)

        #expect(down <= current)
        #expect(up >= current)
        #expect(DiagramZoom.canStepDown(from: value) == (down < current))
        #expect(DiagramZoom.canStepUp(from: value) == (up > current))
        #expect(down == current || DiagramZoom.ladder.contains(down))
        #expect(up == current || DiagramZoom.ladder.contains(up))
    }

    @Test("the floor sits below the ladder so Fit can reach a diagram the buttons cannot")
    func floorLeavesRoomForFit() {
        #expect(DiagramZoom.minimum < DiagramZoom.ladder[0])
        #expect(DiagramZoom.clamped(0.02) == 0.02)
        #expect(DiagramZoom.clamped(0.001) == DiagramZoom.minimum)
    }
}

//
//  DiagramScrollZoomTests.swift
//  TableProTests
//
//  Pins which scrolls zoom a diagram and by how much, independent of any event or view.
//

import AppKit
@testable import TablePro
import Testing

struct DiagramScrollZoomTests {
    private func input(
        deltaY: CGFloat,
        modifierFlags: NSEvent.ModifierFlags = .command,
        precise: Bool = false,
        inverted: Bool = false,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = []
    ) -> DiagramScrollZoom.Input {
        DiagramScrollZoom.Input(
            modifierFlags: modifierFlags,
            phase: phase,
            momentumPhase: momentumPhase,
            scrollingDeltaY: deltaY,
            hasPreciseScrollingDeltas: precise,
            isDirectionInvertedFromDevice: inverted
        )
    }

    private func zoomFactor(_ intent: DiagramScrollZoom.Intent) -> CGFloat? {
        guard case .zoom(let factor) = intent else { return nil }
        return factor
    }

    private func isZoom(_ intent: DiagramScrollZoom.Intent, by expected: CGFloat) -> Bool {
        guard let factor = zoomFactor(intent) else { return false }
        return abs(factor - expected) < 1e-12
    }

    @Test("One wheel notch away from the user zooms in by about ten percent")
    func wheelNotchZoomsIn() {
        var zoom = DiagramScrollZoom()
        #expect(isZoom(zoom.intent(for: input(deltaY: 1)), by: exp(0.1)))
    }

    @Test("A trackpad travels as far per point as a wheel does per line")
    func preciseDeltasMatchLineDeltas() {
        var zoom = DiagramScrollZoom()
        let line = zoomFactor(zoom.intent(for: input(deltaY: 1)))
        #expect(isZoom(zoom.intent(for: input(deltaY: 10, precise: true)), by: line ?? 0))
    }

    @Test("Natural scrolling does not reverse which way the wheel zooms")
    func invertedDirectionFollowsThePhysicalDevice() {
        var zoom = DiagramScrollZoom()
        #expect(isZoom(zoom.intent(for: input(deltaY: -1, inverted: true)), by: exp(0.1)))
    }

    @Test("A notch in and a notch out land on the magnification they started from")
    func opposingNotchesCancel() throws {
        var zoom = DiagramScrollZoom()
        let zoomIn = try #require(zoomFactor(zoom.intent(for: input(deltaY: 1))))
        let zoomOut = try #require(zoomFactor(zoom.intent(for: input(deltaY: -1))))
        #expect(abs(1.5 * zoomIn * zoomOut - 1.5) < 1e-12)
    }

    @Test("An accelerated wheel event zooms no further than three notches")
    func acceleratedEventIsCapped() {
        var zoom = DiagramScrollZoom()
        #expect(isZoom(zoom.intent(for: input(deltaY: 12)), by: exp(0.3)))
        #expect(isZoom(zoom.intent(for: input(deltaY: -40, precise: true)), by: exp(-0.3)))
    }

    @Test(
        "A scroll without Command alone scrolls",
        arguments: [
            NSEvent.ModifierFlags().rawValue,
            NSEvent.ModifierFlags.option.rawValue,
            NSEvent.ModifierFlags.control.rawValue,
            NSEvent.ModifierFlags([.command, .shift]).rawValue,
            NSEvent.ModifierFlags([.command, .option]).rawValue,
            NSEvent.ModifierFlags([.command, .control]).rawValue
        ]
    )
    func otherChordsScroll(rawModifierFlags: UInt) {
        var zoom = DiagramScrollZoom()
        let intent = zoom.intent(for: input(deltaY: 1, modifierFlags: NSEvent.ModifierFlags(rawValue: rawModifierFlags)))
        #expect(intent == .scroll)
    }

    @Test("Caps Lock, Fn and the keypad flag leave Command zooming")
    func nonChordFlagsAreIgnored() {
        var zoom = DiagramScrollZoom()
        let flags: NSEvent.ModifierFlags = [.command, .capsLock, .function, .numericPad]
        #expect(isZoom(zoom.intent(for: input(deltaY: 1, modifierFlags: flags)), by: exp(0.1)))
    }

    @Test("A swipe that began as a scroll keeps scrolling after Command goes down")
    func scrollGestureIgnoresALateCommand() {
        var zoom = DiagramScrollZoom()
        #expect(zoom.intent(for: input(deltaY: 0, modifierFlags: [], precise: true, phase: .began)) == .scroll)
        #expect(zoom.intent(for: input(deltaY: 8, modifierFlags: .command, precise: true, phase: .changed)) == .scroll)
    }

    @Test("A swipe that began with Command keeps zooming after Command comes up")
    func zoomGestureSurvivesReleasingCommand() {
        var zoom = DiagramScrollZoom()
        _ = zoom.intent(for: input(deltaY: 0, modifierFlags: .command, precise: true, phase: .mayBegin))
        let intent = zoom.intent(for: input(deltaY: 8, modifierFlags: [], precise: true, phase: .changed))
        #expect(isZoom(intent, by: exp(0.08)))
    }

    @Test("Momentum after a zoom swipe is swallowed, and after a scroll swipe it scrolls")
    func momentumFollowsTheGesture() {
        var zoom = DiagramScrollZoom()
        _ = zoom.intent(for: input(deltaY: 0, precise: true, phase: .began))
        _ = zoom.intent(for: input(deltaY: 0, precise: true, phase: .ended))
        #expect(zoom.intent(for: input(deltaY: 20, precise: true, momentumPhase: .changed)) == .ignore)

        _ = zoom.intent(for: input(deltaY: 0, modifierFlags: [], precise: true, phase: .began))
        _ = zoom.intent(for: input(deltaY: 0, modifierFlags: [], precise: true, phase: .ended))
        #expect(zoom.intent(for: input(deltaY: 20, modifierFlags: .command, precise: true, momentumPhase: .changed)) == .scroll)
    }

    @Test("A wheel event after a zoom swipe decides for itself")
    func wheelEventsAreNotLatched() {
        var zoom = DiagramScrollZoom()
        _ = zoom.intent(for: input(deltaY: 0, precise: true, phase: .began))
        #expect(zoom.intent(for: input(deltaY: 1, modifierFlags: [])) == .scroll)
    }

    @Test("A zero or non-finite delta zooms by nothing")
    func degenerateDeltasLeaveTheZoomAlone() {
        var zoom = DiagramScrollZoom()
        #expect(zoomFactor(zoom.intent(for: input(deltaY: 0))) == 1)
        #expect(zoomFactor(zoom.intent(for: input(deltaY: .nan))) == 1)
        #expect(zoomFactor(zoom.intent(for: input(deltaY: .infinity, precise: true))) == 1)
    }
}

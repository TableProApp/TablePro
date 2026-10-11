//
//  ResultMapScrollRoutingTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// A stock `MKMapView` swallows every scroll over it, so a map in the row inspector would stop the
/// field list from scrolling. The decision is pure so it is pinned here without a map view.
struct ResultMapScrollRoutingTests {
    private func input(
        modifierFlags: NSEvent.ModifierFlags = [],
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = [],
        deltaY: CGFloat = 1,
        precise: Bool = false
    ) -> DiagramScrollZoom.Input {
        DiagramScrollZoom.Input(
            modifierFlags: modifierFlags,
            phase: phase,
            momentumPhase: momentumPhase,
            scrollingDeltaY: deltaY,
            hasPreciseScrollingDeltas: precise,
            isDirectionInvertedFromDevice: false
        )
    }

    private func route(
        _ routing: inout ResultMapScrollRouting,
        _ input: DiagramScrollZoom.Input,
        yields: Bool = true,
        enclosed: Bool = true
    ) -> ResultMapScrollRouting.Destination {
        routing.destination(
            for: input,
            yieldsToEnclosingScrollView: yields,
            hasEnclosingScrollView: enclosed
        )
    }

    @Test(
        "A surface that does not yield keeps every scroll, as the result Map always has",
        arguments: [NSEvent.ModifierFlags().rawValue, NSEvent.ModifierFlags.command.rawValue]
    )
    func resultMapKeepsEveryScroll(rawModifierFlags: UInt) {
        let flags = NSEvent.ModifierFlags(rawValue: rawModifierFlags)
        var routing = ResultMapScrollRouting()
        #expect(route(&routing, input(modifierFlags: flags), yields: false) == .map)
        #expect(route(&routing, input(modifierFlags: flags, phase: .began, precise: true), yields: false) == .map)
        #expect(route(&routing, input(modifierFlags: flags, phase: .changed, precise: true), yields: false) == .map)
        #expect(route(&routing, input(modifierFlags: flags, momentumPhase: .changed, precise: true), yields: false) == .map)
    }

    @Test("With no scroll view around it, as in the pop-out window, the map keeps every scroll")
    func noEnclosingScrollViewKeepsEveryScroll() {
        var routing = ResultMapScrollRouting()
        #expect(route(&routing, input(), enclosed: false) == .map)
        #expect(route(&routing, input(phase: .began, precise: true), enclosed: false) == .map)
        #expect(route(&routing, input(phase: .changed, precise: true), enclosed: false) == .map)
    }

    @Test("A plain wheel notch scrolls the list")
    func plainWheelScrollsTheList() {
        var routing = ResultMapScrollRouting()
        #expect(route(&routing, input()) == .enclosingScrollView)
    }

    @Test("A Command wheel notch stays with the map")
    func commandWheelStaysWithTheMap() {
        var routing = ResultMapScrollRouting()
        #expect(route(&routing, input(modifierFlags: .command)) == .map)
        #expect(route(&routing, input(modifierFlags: [.command, .capsLock])) == .map)
    }

    @Test(
        "Any chord other than Command alone scrolls the list",
        arguments: [
            NSEvent.ModifierFlags.option.rawValue,
            NSEvent.ModifierFlags.control.rawValue,
            NSEvent.ModifierFlags.shift.rawValue,
            NSEvent.ModifierFlags([.command, .shift]).rawValue,
            NSEvent.ModifierFlags([.command, .option]).rawValue
        ]
    )
    func otherChordsScrollTheList(rawModifierFlags: UInt) {
        var routing = ResultMapScrollRouting()
        let flags = NSEvent.ModifierFlags(rawValue: rawModifierFlags)
        #expect(route(&routing, input(modifierFlags: flags)) == .enclosingScrollView)
    }

    @Test("A swipe that began plain scrolls the list to its end, momentum included")
    func plainSwipeBelongsToTheList() {
        var routing = ResultMapScrollRouting()
        #expect(route(&routing, input(phase: .began, deltaY: 0, precise: true)) == .enclosingScrollView)
        #expect(route(&routing, input(phase: .changed, deltaY: 8, precise: true)) == .enclosingScrollView)
        #expect(
            route(&routing, input(modifierFlags: .command, phase: .changed, deltaY: 8, precise: true))
                == .enclosingScrollView
        )
        #expect(route(&routing, input(phase: .ended, deltaY: 0, precise: true)) == .enclosingScrollView)
        #expect(
            route(&routing, input(modifierFlags: .command, momentumPhase: .changed, deltaY: 6, precise: true))
                == .enclosingScrollView
        )
    }

    @Test("A swipe that began with Command stays with the map after Command comes up")
    func commandSwipeBelongsToTheMap() {
        var routing = ResultMapScrollRouting()
        #expect(route(&routing, input(modifierFlags: .command, phase: .mayBegin, deltaY: 0, precise: true)) == .map)
        #expect(route(&routing, input(modifierFlags: .command, phase: .began, deltaY: 0, precise: true)) == .map)
        #expect(route(&routing, input(phase: .changed, deltaY: 8, precise: true)) == .map)
        #expect(route(&routing, input(phase: .ended, deltaY: 0, precise: true)) == .map)
        #expect(route(&routing, input(momentumPhase: .changed, deltaY: 6, precise: true)) == .map)
    }

    @Test("The next swipe decides for itself")
    func eachSwipeIsLatchedOnItsOwn() {
        var routing = ResultMapScrollRouting()
        _ = route(&routing, input(modifierFlags: .command, phase: .began, deltaY: 0, precise: true))
        _ = route(&routing, input(modifierFlags: .command, phase: .ended, deltaY: 0, precise: true))
        #expect(route(&routing, input(phase: .began, deltaY: 0, precise: true)) == .enclosingScrollView)
        #expect(route(&routing, input(phase: .changed, deltaY: 8, precise: true)) == .enclosingScrollView)
    }
}

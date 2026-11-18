//
//  EditorTabMiddleClickTests.swift
//  TableProTests
//

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import TablePro

// `NSEvent.mouseEvent(with:…)` cannot carry a button number, so the gesture is driven through the view's entry points.
@MainActor
struct EditorTabMiddleClickTests {
    private func makeTab() -> (EditorTabItemView, EditorTabStripView, EditorTabCommandRecorder) {
        let recorder = EditorTabCommandRecorder()
        let strip = EditorTabStripView(frame: NSRect(x: 0, y: 0, width: 652, height: EditorTabStripLayout.bandHeight))
        strip.commands = .stub(recorder: recorder)
        let item = EditorTabItem.sample()
        strip.apply([item])
        strip.layoutSubtreeIfNeeded()
        let view = strip.itemView(for: item.id) ?? EditorTabItemView(item: item)
        return (view, strip, recorder)
    }

    private func centre(of view: NSView) -> NSPoint {
        NSPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    @Test("A middle-click on a tab closes it")
    func middleClickClosesTheTab() {
        let (view, strip, recorder) = makeTab()

        view.beginMiddleClick()
        view.endMiddleClick(atViewPoint: centre(of: view))

        #expect(recorder.closed == [view.item.id])
        withExtendedLifetime(strip) {}
    }

    @Test("Releasing off the tab closes nothing")
    func releasingOffTheTabClosesNothing() {
        let (view, strip, recorder) = makeTab()

        view.beginMiddleClick()
        view.endMiddleClick(atViewPoint: NSPoint(x: view.bounds.maxX + 40, y: view.bounds.midY))

        #expect(recorder.closed.isEmpty)
        withExtendedLifetime(strip) {}
    }

    @Test("A release without a press closes nothing")
    func releaseWithoutAPressClosesNothing() {
        let (view, strip, recorder) = makeTab()

        view.endMiddleClick(atViewPoint: centre(of: view))

        #expect(recorder.closed.isEmpty)
        withExtendedLifetime(strip) {}
    }

    @Test("A second release without a second press closes nothing")
    func secondReleaseClosesNothing() {
        let (view, strip, recorder) = makeTab()

        view.beginMiddleClick()
        view.endMiddleClick(atViewPoint: centre(of: view))
        view.endMiddleClick(atViewPoint: centre(of: view))

        #expect(recorder.closed == [view.item.id])
        withExtendedLifetime(strip) {}
    }

    @Test("A release from another button closes nothing")
    func releaseFromAnotherButtonClosesNothing() throws {
        let (view, strip, recorder) = makeTab()
        let event = try #require(
            NSEvent.mouseEvent(
                with: .otherMouseUp,
                location: centre(of: view),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
            )
        )

        view.beginMiddleClick()
        view.otherMouseUp(with: event)

        #expect(event.isMiddleButton == false)
        #expect(recorder.closed.isEmpty)
        withExtendedLifetime(strip) {}
    }
}

// `NSEvent(cgEvent:)` is the one factory that can carry a button number into a test.
struct NSEventMouseButtonTests {
    private func press(_ button: CGMouseButton) throws -> NSEvent {
        let cgEvent = try #require(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseDown,
                mouseCursorPosition: .zero,
                mouseButton: button
            )
        )
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    @Test("The wheel button is the middle button")
    func centreButtonIsTheMiddleButton() throws {
        let event = try press(.center)
        #expect(event.isMiddleButton)
    }

    @Test("Neither of the two main buttons is the middle button")
    func mainButtonsAreNotTheMiddleButton() throws {
        let left = try press(.left)
        let right = try press(.right)
        #expect(left.isMiddleButton == false)
        #expect(right.isMiddleButton == false)
    }
}

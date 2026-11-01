//
//  FieldResizeHandleTests.swift
//  TableProTests
//
//  The handle owns the mouse from press to release, so the drag is measured from the press and
//  the release always reports where it ended.
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct FieldResizeHandleTests {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 400),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )

    private func event(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 50, y: y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @Test("Dragging down reports a growing delta, and the release reports the final one")
    func reportsDownwardDrag() {
        let view = FieldResizeHandleView()
        var drags: [Double] = []
        var ended: Double?
        view.onDrag = { drags.append($0) }
        view.onEnd = { ended = $0 }

        view.mouseDown(with: event(.leftMouseDown, y: 300))
        view.mouseDragged(with: event(.leftMouseDragged, y: 290))
        view.mouseDragged(with: event(.leftMouseDragged, y: 260))
        view.mouseUp(with: event(.leftMouseUp, y: 250))

        #expect(drags == [10, 40])
        #expect(ended == 50)
    }

    @Test("Dragging up reports a negative delta")
    func reportsUpwardDrag() {
        let view = FieldResizeHandleView()
        var ended: Double?
        view.onEnd = { ended = $0 }

        view.mouseDown(with: event(.leftMouseDown, y: 300))
        view.mouseUp(with: event(.leftMouseUp, y: 330))

        #expect(ended == -30)
    }

    /// The press has to land on the AppKit view, not on SwiftUI's hosting view: a gesture there lost
    /// the mouse to the inspector's table a few points into the drag.
    @Test("A press on the grip lands on the handle view")
    func pressLandsOnHandle() throws {
        let container = ResizableEditorContainer(height: .constant(120), range: 80...600) {
            Color.clear
        }
        let hosting = NSHostingView(rootView: container)
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let handle = try #require(Self.firstSubview(of: FieldResizeHandleView.self, in: hosting))
        let center = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let root = try #require(hosting.superview)

        #expect(root.hitTest(root.convert(center, from: nil)) === handle)
    }

    private static func firstSubview<View: NSView>(of type: View.Type, in view: NSView) -> View? {
        for subview in view.subviews {
            if let match = subview as? View ?? firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    @Test("A handle removed under the pointer stops reporting a hover")
    func removalEndsHover() {
        let view = FieldResizeHandleView()
        var hovers: [Bool] = []
        view.onHover = { hovers.append($0) }
        window.contentView?.addSubview(view)

        view.mouseEntered(with: event(.mouseMoved, y: 10))
        view.removeFromSuperview()

        #expect(hovers == [true, false])
    }

    /// A release with no press on the handle belongs to some other drag.
    @Test("A drag that did not start on the handle reports nothing")
    func ignoresStrayEvents() {
        let view = FieldResizeHandleView()
        var reported = false
        view.onDrag = { _ in reported = true }
        view.onEnd = { _ in reported = true }

        view.mouseDragged(with: event(.leftMouseDragged, y: 200))
        view.mouseUp(with: event(.leftMouseUp, y: 200))

        #expect(reported == false)
    }
}

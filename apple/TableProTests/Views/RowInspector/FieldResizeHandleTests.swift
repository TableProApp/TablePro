//
//  FieldResizeHandleTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct FieldResizeHandleTests {
    private let window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }()

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

    private func recordingHandle() -> (FieldResizeHandleView, Recorder) {
        let view = FieldResizeHandleView()
        let recorder = Recorder()
        view.onDrag = { recorder.drags.append($0) }
        view.onEnd = { recorder.ends.append($0) }
        return (view, recorder)
    }

    @Test("Dragging down reports a growing delta, and the release reports the final one")
    func reportsDownwardDrag() {
        let (view, recorder) = recordingHandle()

        view.mouseDown(with: event(.leftMouseDown, y: 300))
        view.mouseDragged(with: event(.leftMouseDragged, y: 290))
        view.mouseDragged(with: event(.leftMouseDragged, y: 260))
        view.mouseUp(with: event(.leftMouseUp, y: 250))

        #expect(recorder.drags == [10, 40])
        #expect(recorder.ends == [50])
    }

    @Test("Dragging up reports a negative delta")
    func reportsUpwardDrag() {
        let (view, recorder) = recordingHandle()

        view.mouseDown(with: event(.leftMouseDown, y: 300))
        view.mouseDragged(with: event(.leftMouseDragged, y: 320))
        view.mouseUp(with: event(.leftMouseUp, y: 330))

        #expect(recorder.ends == [-30])
    }

    @Test("A click on the grip resizes nothing")
    func clickReportsNothing() {
        let (view, recorder) = recordingHandle()

        view.mouseDown(with: event(.leftMouseDown, y: 300))
        view.mouseUp(with: event(.leftMouseUp, y: 300))

        #expect(recorder.drags.isEmpty)
        #expect(recorder.ends.isEmpty)
    }

    @Test("A drag that did not start on the handle reports nothing")
    func ignoresStrayEvents() {
        let (view, recorder) = recordingHandle()

        view.mouseDragged(with: event(.leftMouseDragged, y: 200))
        view.mouseUp(with: event(.leftMouseUp, y: 200))

        #expect(recorder.drags.isEmpty)
        #expect(recorder.ends.isEmpty)
    }

    @Test("A disabled handle takes no press, no hover and no hit")
    func disabledHandleIsInert() {
        let (view, recorder) = recordingHandle()
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 11)
        view.isEnabled = false

        view.mouseEntered(with: event(.mouseMoved, y: 5))
        view.mouseDown(with: event(.leftMouseDown, y: 300))
        view.mouseDragged(with: event(.leftMouseDragged, y: 250))
        view.mouseUp(with: event(.leftMouseUp, y: 250))

        #expect(view.isHighlighted == false)
        #expect(view.hitTest(NSPoint(x: 50, y: 5)) == nil)
        #expect(recorder.ends.isEmpty)
    }

    @Test("Disabling the handle mid-drag drops the drag")
    func disablingCancelsDrag() {
        let (view, recorder) = recordingHandle()

        view.mouseDown(with: event(.leftMouseDown, y: 300))
        view.mouseDragged(with: event(.leftMouseDragged, y: 280))
        view.isEnabled = false
        view.mouseUp(with: event(.leftMouseUp, y: 250))

        #expect(recorder.ends.isEmpty)
        #expect(view.isHighlighted == false)
    }

    @Test("A handle removed mid-drag ends neither the drag nor the hover later")
    func removalDropsDragAndHover() {
        let (view, recorder) = recordingHandle()
        window.contentView?.addSubview(view)

        view.mouseEntered(with: event(.mouseMoved, y: 10))
        view.mouseDown(with: event(.leftMouseDown, y: 300))
        view.mouseDragged(with: event(.leftMouseDragged, y: 280))
        view.removeFromSuperview()
        view.mouseUp(with: event(.leftMouseUp, y: 250))

        #expect(recorder.ends.isEmpty)
        #expect(view.isHighlighted == false)
    }

    private func mountInList(_ heights: InspectorFieldHeightStore) async throws -> FieldResizeHandleView {
        let list = List {
            ResizableEditorContainer(column: "payload", defaultHeight: 120, range: 80...600, heights: heights) {
                Color.clear
            }
        }
        .listStyle(.plain)
        let hosting = NSHostingView(rootView: list)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        window.contentView = hosting
        try await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            return Self.firstSubview(of: FieldResizeHandleView.self, in: hosting) != nil
        }
        return try #require(Self.firstSubview(of: FieldResizeHandleView.self, in: hosting))
    }

    private func windowEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    // The table took the mouse from a SwiftUI gesture in its row; the press must land on the AppKit view instead.
    @Test("Inside a List, a press on the grip lands on the handle view")
    func pressInListLandsOnHandle() async throws {
        let scratch = try EphemeralDefaults()
        let handle = try await mountInList(InspectorFieldHeightStore(defaults: scratch.defaults))
        defer { window.contentView = nil }

        let center = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let root = try #require(handle.window?.contentView?.superview)
        #expect(root.hitTest(root.convert(center, from: nil)) === handle)
    }

    // Driven on the view: an offscreen test window is never key, so `sendEvent` delivers no mouse event.
    @Test("Inside a List, a drag released off the handle stores the column's height")
    func dragInListStoresHeight() async throws {
        let scratch = try EphemeralDefaults()
        let heights = InspectorFieldHeightStore(defaults: scratch.defaults)
        let handle = try await mountInList(heights)
        defer { window.contentView = nil }

        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let end = NSPoint(x: start.x + 120, y: start.y - 40)
        handle.mouseDown(with: windowEvent(.leftMouseDown, at: start))
        handle.mouseDragged(with: windowEvent(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 20)))
        handle.mouseDragged(with: windowEvent(.leftMouseDragged, at: end))
        handle.mouseUp(with: windowEvent(.leftMouseUp, at: end))

        #expect(heights.height(for: "payload") == 160)
        #expect(InspectorFieldHeightStore(defaults: scratch.defaults).height(for: "payload") == 160)
    }

    private static func firstSubview<View: NSView>(of type: View.Type, in view: NSView) -> View? {
        for subview in view.subviews {
            if let match = subview as? View ?? firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}

private final class Recorder {
    var drags: [Double] = []
    var ends: [Double] = []
}

//
//  EditorTabLateDragTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

// A busy main thread reads the press, the drag and the release from the queue after the button is already up.
@MainActor
struct EditorTabLateDragTests {
    private func makeStrip(
        titles: [String] = ["Album", "Artist", "Genre"],
        recorder: EditorTabCommandRecorder = EditorTabCommandRecorder(),
        connectionId: UUID = UUID()
    ) -> (EditorTabStripView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 652, height: EditorTabStripLayout.bandHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let strip = EditorTabStripView(frame: NSRect(origin: .zero, size: window.frame.size))
        strip.commands = .stub(recorder: recorder, connectionId: connectionId)
        strip.isPrimaryButtonDown = { false }
        window.contentView = strip
        strip.apply(EditorTabItem.samples(titles: titles))
        strip.layoutSubtreeIfNeeded()
        return (strip, window)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func windowCentre(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    @Test("A drag read after its release starts no session and opens the tab where the button went up")
    func lateDragOutOfTheStripTearsOffAtTheRelease() throws {
        let recorder = EditorTabCommandRecorder()
        let (strip, window) = makeStrip(recorder: recorder)
        defer { window.orderOut(nil) }
        let view = try #require(strip.itemView(for: strip.items[2].id))
        let press = windowCentre(of: view)
        let release = NSPoint(x: press.x, y: -20_000)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: press, in: window))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: release, in: window))

        #expect(strip.reorder == nil)
        #expect(view.alphaValue == 1)
        #expect(recorder.tornOff.isEmpty)

        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: release, in: window))

        #expect(recorder.tornOff.map(\.0) == [view.item.id])
        #expect(recorder.tornOff.first?.1 == window.convertPoint(toScreen: release))
    }

    @Test("A drag read after its release that the policy refuses opens nothing")
    func lateDragOfATabThatCannotMoveOpensNothing() throws {
        let recorder = EditorTabCommandRecorder()
        let (strip, window) = makeStrip(recorder: recorder)
        defer { window.orderOut(nil) }
        strip.commands = .stub(recorder: recorder, canTearOff: false)
        let view = try #require(strip.itemView(for: strip.items[2].id))
        let press = windowCentre(of: view)
        let release = NSPoint(x: press.x, y: -20_000)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: press, in: window))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: release, in: window))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: release, in: window))

        #expect(recorder.tornOff.isEmpty)
    }

    @Test("Escape read before the queued release cancels the late drag")
    func escapeBeforeTheQueuedReleaseCancels() throws {
        let recorder = EditorTabCommandRecorder()
        let (strip, window) = makeStrip(recorder: recorder)
        defer { window.orderOut(nil) }
        let view = try #require(strip.itemView(for: strip.items[2].id))
        let press = windowCentre(of: view)
        let release = NSPoint(x: press.x, y: -20_000)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: press, in: window))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: release, in: window))
        #expect(strip.isWatchingForDragCancel)
        strip.noteKeyDuringDrag(KeyCode.escape.rawValue)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: release, in: window))

        #expect(recorder.tornOff.isEmpty)
        #expect(!strip.isWatchingForDragCancel)
    }

    @Test("A late drag after a cancelled one is not cancelled")
    func lateDragAfterACancelledOneTearsOff() throws {
        let recorder = EditorTabCommandRecorder()
        let (strip, window) = makeStrip(recorder: recorder)
        defer { window.orderOut(nil) }
        let view = try #require(strip.itemView(for: strip.items[2].id))
        let press = windowCentre(of: view)
        let release = NSPoint(x: press.x, y: -20_000)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: press, in: window))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: release, in: window))
        strip.noteKeyDuringDrag(KeyCode.escape.rawValue)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: release, in: window))
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: press, in: window))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: release, in: window))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: release, in: window))

        #expect(recorder.tornOff.map(\.0) == [view.item.id])
    }

    @Test("A late drop on another slot of its own strip moves the tab there")
    func lateDropOnItsOwnStripReorders() throws {
        let recorder = EditorTabCommandRecorder()
        let (strip, window) = makeStrip(recorder: recorder)
        defer { window.orderOut(nil) }
        let first = try #require(strip.itemView(for: strip.items[0].id))
        let last = try #require(strip.itemView(for: strip.items[2].id))

        strip.settleDrop(of: first, atWindowPoint: windowCentre(of: last))

        let order = strip.items.map(\.id)
        #expect(recorder.moved.map(\.0) == [first.item.id])
        #expect(recorder.moved.map(\.1) == [2])
        #expect(order.last == first.item.id)
        #expect(strip.reorder == nil)
    }

    @Test("A late drop on another window's strip of the same connection hands the tab over")
    func lateDropOnAnotherStripOfTheConnectionReceivesTheTab() throws {
        let connectionId = UUID()
        let sourceRecorder = EditorTabCommandRecorder()
        let targetRecorder = EditorTabCommandRecorder()
        let (source, sourceWindow) = makeStrip(recorder: sourceRecorder, connectionId: connectionId)
        let (target, targetWindow) = makeStrip(
            titles: ["Customer", "Invoice"],
            recorder: targetRecorder,
            connectionId: connectionId
        )
        defer {
            sourceWindow.orderOut(nil)
            targetWindow.orderOut(nil)
        }
        let moved = try #require(source.itemView(for: source.items[1].id))
        let anchor = try #require(target.itemView(for: target.items[0].id))
        let leadingEdge = anchor.convert(NSPoint(x: 1, y: anchor.bounds.midY), to: nil)

        target.settleDrop(of: moved, atWindowPoint: leadingEdge)

        #expect(targetRecorder.received.map(\.0) == [moved.item.id])
        #expect(targetRecorder.received.map(\.1) == [0])
        #expect(sourceRecorder.moved.isEmpty)
    }

    @Test("A late drop on a strip of another connection is refused")
    func lateDropOnAnotherConnectionsStripIsRefused() throws {
        let targetRecorder = EditorTabCommandRecorder()
        let (source, sourceWindow) = makeStrip()
        let (target, targetWindow) = makeStrip(titles: ["Customer"], recorder: targetRecorder)
        defer {
            sourceWindow.orderOut(nil)
            targetWindow.orderOut(nil)
        }
        let moved = try #require(source.itemView(for: source.items[1].id))
        let anchor = try #require(target.itemView(for: target.items[0].id))

        target.settleDrop(of: moved, atWindowPoint: windowCentre(of: anchor))

        #expect(targetRecorder.received.isEmpty)
    }

    @Test("A release over a tab in a connection window resolves to that window's strip, and over the grid to none")
    func releasePointResolvesTheStripUnderIt() throws {
        let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_200, height: 800))
        defer { fixture.tearDown() }
        let strip = fixture.workspace.panes.tabStrip.stripView
        strip.commands = .stub()
        strip.apply(EditorTabItem.samples(titles: ["Album", "Artist", "Genre"]))
        fixture.split.tabStripAccessory.setBandVisible(true)
        fixture.window.layoutIfNeeded()
        strip.layoutSubtreeIfNeeded()
        let tab = try #require(strip.itemView(for: strip.items[1].id))

        #expect(EditorTabStripView.strip(in: fixture.window, atWindowPoint: windowCentre(of: tab)) === strip)
        let middle = NSPoint(x: fixture.window.frame.width / 2, y: fixture.window.frame.height / 3)
        #expect(EditorTabStripView.strip(in: fixture.window, atWindowPoint: middle) == nil)
    }
}

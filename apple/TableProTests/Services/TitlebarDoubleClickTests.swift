//
//  TitlebarDoubleClickTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

/// The connection window as the app builds it: its content reaches under a transparent titlebar, where a
/// double-click used to land on the content and never reach AppKit's titlebar action.
@MainActor
struct TitlebarDoubleClickTests {
    @MainActor
    private struct Hosted {
        let window: ContentWindow
        let workspace: ConnectionWorkspace

        func close() {
            window.orderOut(nil)
            window.contentViewController = nil
            workspace.teardown()
        }

        /// Points along the titlebar band, sorted by whether the content or the titlebar's own views are under them.
        func bandPoints() -> (overContent: [NSPoint], overTitlebar: [NSPoint]) {
            var overContent: [NSPoint] = []
            var overTitlebar: [NSPoint] = []
            guard let contentView = window.contentView, let frameView = contentView.superview else { return ([], []) }
            let y = (window.contentLayoutRect.maxY + window.frame.height) / 2
            for x in stride(from: 10.0, to: window.frame.width - 10, by: 20) {
                let point = NSPoint(x: x, y: y)
                guard let hit = frameView.hitTest(point) else { continue }
                if hit.isDescendant(of: contentView) {
                    overContent.append(point)
                } else {
                    overTitlebar.append(point)
                }
            }
            return (overContent, overTitlebar)
        }
    }

    private func host() throws -> Hosted {
        let connection = TestFixtures.makeConnection(name: "Titlebar")
        let workspace = ConnectionWorkspace(
            connectionId: connection.id, payload: nil, autoConnect: false, payloadConnection: connection,
            session: nil, sessionState: nil, trailingPaneState: nil, phase: .connecting
        )
        let window = try #require(TabWindowController.makeEditorWindow() as? ContentWindow)
        window.isReleasedWhenClosed = false
        let split = MainSplitViewController(payload: nil, sessionState: nil, adopting: workspace)
        window.contentViewController = split
        split.installTabStripAccessory(on: window)
        window.setContentSize(NSSize(width: 1_200, height: 800))
        window.orderFront(nil)
        window.layoutIfNeeded()
        return Hosted(window: window, workspace: workspace)
    }

    private func doubleClick(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1
        ))
    }

    @Test("The titlebar double-click follows the Desktop & Dock setting")
    func actionFollowsTheSetting() {
        #expect(TitlebarDoubleClickAction(setting: nil, minimizesLegacy: false) == .zoom)
        #expect(TitlebarDoubleClickAction(setting: nil, minimizesLegacy: true) == .minimize)
        #expect(TitlebarDoubleClickAction(setting: "Maximize", minimizesLegacy: true) == .zoom)
        #expect(TitlebarDoubleClickAction(setting: "Fill", minimizesLegacy: false) == .zoom)
        #expect(TitlebarDoubleClickAction(setting: "Minimize", minimizesLegacy: false) == .minimize)
        #expect(TitlebarDoubleClickAction(setting: "None", minimizesLegacy: true) == .none)
    }

    @Test("Content under the titlebar takes the double-click, and the titlebar's own views are left to AppKit")
    func contentUnderTheTitlebarTakesIt() throws {
        let hosted = try host()
        defer { hosted.close() }
        let points = hosted.bandPoints()

        try #require(!points.overContent.isEmpty, "The fixture needs content under the transparent titlebar")
        #expect(points.overContent.allSatisfy { hosted.window.takesTitlebarDoubleClick(at: $0) })
        #expect(points.overTitlebar.allSatisfy { !hosted.window.takesTitlebarDoubleClick(at: $0) })

        let belowTitlebar = NSPoint(x: hosted.window.frame.width / 2, y: hosted.window.contentLayoutRect.maxY - 100)
        #expect(!hosted.window.takesTitlebarDoubleClick(at: belowTitlebar), "Content below the titlebar keeps its clicks")
    }

    @Test("A double-click on the content under the titlebar zooms the window")
    func doubleClickZooms() throws {
        let hosted = try host()
        defer { hosted.close() }
        let previous = ContentWindow.titlebarDoubleClickAction
        ContentWindow.titlebarDoubleClickAction = { .zoom }
        defer { ContentWindow.titlebarDoubleClickAction = previous }
        let point = try #require(hosted.bandPoints().overContent.first)
        let before = hosted.window.frame

        hosted.window.sendEvent(try doubleClick(at: point, in: hosted.window))

        #expect(hosted.window.frame != before, "The window should take its zoomed frame")
    }
}

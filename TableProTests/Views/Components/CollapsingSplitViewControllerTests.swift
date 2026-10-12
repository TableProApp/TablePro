//
//  CollapsingSplitViewControllerTests.swift
//  TableProTests
//
//  The Users & Roles principal list collapses while the tab is too narrow for it and for nothing
//  else. A list collapsed any other way has no divider left to drag it back by.
//

import AppKit
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct CollapsingSplitViewControllerTests {
    private static let primaryMinimum: CGFloat = 200
    private static let secondaryMinimum: CGFloat = 400

    @Test("The list cannot be dragged shut")
    func dragDoesNotCollapse() async throws {
        let window = host()
        defer { window.close() }
        let controller = try #require(splitController(in: window.contentView))
        let primary = try #require(controller.splitViewItems.first)

        #expect(await settle(window) { primary.viewController.view.frame.width > 0 })
        controller.splitView.setPosition(0, ofDividerAt: 0)

        #expect(!(await settle(window) { primary.isCollapsed }))
    }

    @Test("A list restored collapsed opens again once there is room")
    func restoredCollapseReopens() async throws {
        let window = host()
        defer { window.close() }
        let controller = try #require(splitController(in: window.contentView))
        let primary = try #require(controller.splitViewItems.first)

        primary.isCollapsed = true

        #expect(await settle(window) { !primary.isCollapsed })
    }

    private func host() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: AutosavingSplitView(
                autosaveName: "CollapsingSplitViewControllerTests",
                primaryMinimum: Self.primaryMinimum,
                secondaryMinimum: Self.secondaryMinimum,
                collapsesPrimaryWhenTight: true
            ) {
                Text("Principals")
            } secondary: {
                Text("Detail")
            }
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// SwiftUI lays the representable out on its own pass, so the split controller's
    /// `viewDidLayout` runs after the window's synchronous layout returns.
    private func settle(_ window: NSWindow, until condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 50 {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func splitController(in view: NSView?) -> CollapsingSplitViewController? {
        guard let view else { return nil }
        if let splitView = view as? NSSplitView,
           let controller = splitView.delegate as? CollapsingSplitViewController {
            return controller
        }
        for subview in view.subviews {
            if let found = splitController(in: subview) { return found }
        }
        return nil
    }
}

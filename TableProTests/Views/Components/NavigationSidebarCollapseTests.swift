//
//  NavigationSidebarCollapseTests.swift
//  TableProTests
//
//  A sidebar that is its window's only navigation must not collapse. Dragged shut, it takes every
//  section with it, and the split controller hides the divider it would be dragged back by.
//

import AppKit
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct NavigationSidebarCollapseTests {
    @Test("The connection form's sidebar survives a drag to the window edge")
    func connectionFormSidebarRefusesDrag() throws {
        let split = ConnectionFormSplitViewController(coordinator: ConnectionFormCoordinator(connectionId: nil))
        let window = host(split)
        defer { window.close() }

        try expectSidebarStaysOpen(in: split)
    }

    @Test("A sidebar window's sidebar survives a drag to the window edge")
    func sidebarSplitRefusesDrag() throws {
        let split = SidebarSplitViewController(
            sidebar: List { Text("Section") }.listStyle(.sidebar),
            detail: Text("Detail"),
            sidebarThickness: 200...280,
            idealSidebarThickness: 220,
            detailMinimumThickness: 480
        )
        let window = host(split)
        defer { window.close() }

        try expectSidebarStaysOpen(in: split)
    }

    private func expectSidebarStaysOpen(in split: NSSplitViewController) throws {
        let sidebar = try #require(split.splitViewItems.first)
        #expect(sidebar.behavior == .sidebar)

        split.splitView.setPosition(0, ofDividerAt: 0)
        split.view.layoutSubtreeIfNeeded()

        #expect(!sidebar.isCollapsed)
        #expect(sidebar.viewController.view.frame.width >= sidebar.minimumThickness)

        let showSidebar = NSMenuItem(
            title: "Show Sidebar",
            action: #selector(NSSplitViewController.toggleSidebar(_:)),
            keyEquivalent: ""
        )
        #expect(!split.validateUserInterfaceItem(showSidebar), "Show Sidebar has nothing to do here")
    }

    private func host(_ controller: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 620))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }
}

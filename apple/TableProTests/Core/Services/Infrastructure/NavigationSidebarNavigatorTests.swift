//
//  NavigationSidebarNavigatorTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

/// With the setting on, the connections column holds the navigator in a split of its own, wrapped
/// around the strip's split, so each list keeps its own width and the object browser is never
/// rebuilt.
@MainActor
struct NavigationSidebarNavigatorTests {
    private typealias SidebarHost = NavigationSidebarRailWidthTests.SidebarHost

    private static func enclosingSplitView(of view: NSView) throws -> NSSplitView {
        var current = view.superview
        while let candidate = current {
            if let split = candidate as? NSSplitView { return split }
            current = candidate.superview
        }
        throw NavigatorSplitMissing()
    }

    private struct NavigatorSplitMissing: Error {}

    private static func showNavigator(in host: SidebarHost) {
        host.sidebar.setNavigatorEnabled(true)
        host.sidebar.setRailVisible(true, animated: false)
        host.layout()
    }

    @Test("A navigator shown for the first time opens at its default width")
    func navigatorOpensAtItsDefaultWidth() throws {
        let host = SidebarHost()
        defer { host.tearDown() }

        Self.showNavigator(in: host)

        let navigator = host.sidebar.navigatorController.view
        let split = try Self.enclosingSplitView(of: navigator)
        #expect(navigator.frame.width == ConnectionNavigatorViewController.defaultWidth)
        #expect(host.sidebar.railAllowance == ConnectionNavigatorViewController.defaultWidth + split.dividerThickness)
        #expect(host.frameInSidebar(host.sidebar.objectBrowser.view).minX > 0)
    }

    @Test("A navigator that is not shown reserves no width")
    func hiddenNavigatorReservesNothing() {
        let host = SidebarHost()
        defer { host.tearDown() }

        host.sidebar.setNavigatorEnabled(true)
        host.layout()

        let browser = host.sidebar.objectBrowser.view
        #expect(host.sidebar.showsNavigator)
        #expect(throws: Never.self) { try Self.enclosingSplitView(of: host.sidebar.navigatorController.view) }
        #expect(host.sidebar.railAllowance == 0)
        #expect(host.frameInSidebar(browser).minX == 0)
        #expect(host.frameInSidebar(browser).width == host.sidebar.view.bounds.width)
    }

    @Test("The strip keeps its width while the navigator stands in its place")
    func railKeepsItsWidthThroughTheNavigator() throws {
        let host = SidebarHost()
        defer { host.tearDown() }
        host.sidebar.setRailVisible(true, animated: false)
        host.layout()
        try host.splitView().setPosition(170, ofDividerAt: 0)
        host.layout()

        Self.showNavigator(in: host)
        #expect(host.sidebar.navigatorController.view.frame.width > 0)
        #expect(host.rail.isHiddenOrHasHiddenAncestor)
        host.sidebar.setNavigatorEnabled(false)
        host.sidebar.setRailVisible(true, animated: false)
        host.layout()

        #expect(host.rail.frame.width == 170)
    }

    @Test("The navigator keeps its own width while it is off")
    func navigatorKeepsItsWidthWhileOff() throws {
        let host = SidebarHost()
        defer { host.tearDown() }
        Self.showNavigator(in: host)
        try Self.enclosingSplitView(of: host.sidebar.navigatorController.view).setPosition(260, ofDividerAt: 0)
        host.layout()

        host.sidebar.setNavigatorEnabled(false)
        host.sidebar.setRailVisible(true, animated: false)
        host.layout()
        Self.showNavigator(in: host)

        #expect(host.sidebar.navigatorController.view.frame.width == 260)
    }

    @Test("Turning the navigator on and off keeps the same object browser in the window")
    func objectBrowserIsNeverRebuilt() throws {
        let host = SidebarHost()
        defer { host.tearDown() }
        let browser = host.sidebar.objectBrowser

        Self.showNavigator(in: host)
        let navigatorSplit = try Self.enclosingSplitView(of: host.sidebar.navigatorController.view)
        #expect(browser.view.isDescendant(of: navigatorSplit))
        host.sidebar.setNavigatorEnabled(false)
        Self.showNavigator(in: host)

        #expect(host.sidebar.objectBrowser === browser)
        #expect(browser.view.window === host.window)
        #expect(browser.view.isDescendant(of: host.sidebar.view))
    }

    /// A hidden list that kept the keyboard would take every key the user meant for the window.
    @Test("Hiding the navigator, or turning it off, moves the keyboard out of its list")
    func hidingTheNavigatorHandsTheKeyboardOn() {
        let host = SidebarHost()
        defer { host.tearDown() }
        let navigator = host.sidebar.navigatorController

        Self.showNavigator(in: host)
        host.window.makeFirstResponder(navigator.outlineView)
        #expect(Self.isInside(host.window.firstResponder, navigator.view))
        host.sidebar.setRailVisible(false, animated: false)
        #expect(!Self.isInside(host.window.firstResponder, navigator.view))

        Self.showNavigator(in: host)
        host.window.makeFirstResponder(navigator.outlineView)
        host.sidebar.setNavigatorEnabled(false)
        #expect(!Self.isInside(host.window.firstResponder, navigator.view))
    }

    /// Stands in for the object list, which takes the keyboard the way any list does.
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Turning the setting on or off moves the object browser into another split, which takes it
    /// out of the window for a moment, and AppKit hands the keyboard to the window when a view
    /// holding it leaves.
    @Test("Turning the navigator on and off leaves the keyboard in the object browser")
    func togglingTheNavigatorKeepsTheBrowserFocused() throws {
        let host = SidebarHost()
        defer { host.tearDown() }
        let list = FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.sidebar.objectBrowser.view.addSubview(list)
        host.window.makeFirstResponder(list)
        try #require(host.window.firstResponder === list)

        host.sidebar.setNavigatorEnabled(true)
        #expect(host.window.firstResponder === list)

        host.sidebar.setNavigatorEnabled(false)
        #expect(host.window.firstResponder === list)
    }

    /// A field being edited holds the keyboard through its field editor, which leaves with the edit.
    @Test("Turning the navigator on and off keeps a field in the object browser editing")
    func togglingTheNavigatorKeepsAFieldEditing() throws {
        let host = SidebarHost()
        defer { host.tearDown() }
        let field = NSTextField(string: "orders")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 22)
        host.sidebar.objectBrowser.view.addSubview(field)
        host.window.makeFirstResponder(field)
        try #require(field.currentEditor() != nil)

        host.sidebar.setNavigatorEnabled(true)
        #expect(field.currentEditor() != nil)

        host.sidebar.setNavigatorEnabled(false)
        #expect(field.currentEditor() != nil)
    }

    private static func isInside(_ responder: NSResponder?, _ view: NSView) -> Bool {
        guard let responder = responder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }
}

extension GlobalStateSuites {
    @MainActor
    struct NavigatorWindowTests {
        @Test(
            "With the navigator on, the column stands in a window with one connection",
            .appSettings {
                $0.general.showsConnectionNavigator = true
                $0.general.showWorkspaceRail = true
            }
        )
        func columnStandsWithOneWorkspace() async throws {
            let host = NavigatorWindowHost()
            defer { host.tearDown() }

            host.split.applyRailVisibility(workspaceCount: 1)
            try await waitUntil { host.split.railAllowance > 0 }

            #expect(host.split.isWorkspaceRailVisible)
            #expect(host.split.canToggleWorkspaceRail)
            let context = host.split.menuValidationContext
            #expect(MainSplitViewController.isEnabled(
                #selector(MainSplitViewController.toggleWorkspaceRail(_:)), context: context
            ))
            #expect(!MainSplitViewController.isEnabled(
                #selector(MainSplitViewController.showPreviousWorkspace(_:)), context: context
            ))
        }

        @Test(
            "Hide Connections hides the navigator",
            .appSettings {
                $0.general.showsConnectionNavigator = true
                $0.general.showWorkspaceRail = false
            }
        )
        func showConnectionsHidesTheNavigator() throws {
            let host = NavigatorWindowHost()
            defer { host.tearDown() }

            host.split.applyRailVisibility(workspaceCount: 1)

            #expect(!host.split.isWorkspaceRailVisible)
            let sidebar = try #require(host.split.sidebarSplitItem.viewController as? NavigationSidebarViewController)
            #expect(sidebar.showsNavigator)
        }

        @Test(
            "Turning the navigator off brings the strip's own rule back",
            .appSettings {
                $0.general.showsConnectionNavigator = true
                $0.general.showWorkspaceRail = true
            }
        )
        func turningTheNavigatorOffBringsTheRailRuleBack() throws {
            let host = NavigatorWindowHost()
            defer { host.tearDown() }
            host.split.applyRailVisibility(workspaceCount: 1)
            #expect(host.split.isWorkspaceRailVisible)

            AppSettingsManager.shared.general.showsConnectionNavigator = false
            host.split.applyRailVisibility(workspaceCount: 1)

            #expect(!host.split.isWorkspaceRailVisible)
            let sidebar = try #require(host.split.sidebarSplitItem.viewController as? NavigationSidebarViewController)
            #expect(!sidebar.showsNavigator)
        }
    }
}

@MainActor
private struct NavigatorWindowHost {
    let window: NSWindow
    let split: MainSplitViewController
    let workspace: ConnectionWorkspace

    init() {
        let connection = TestFixtures.makeConnection(name: "Navigator window")
        workspace = ConnectionWorkspace(
            connectionId: connection.id,
            payload: nil,
            autoConnect: false,
            payloadConnection: connection,
            session: nil,
            sessionState: nil,
            trailingPaneState: nil,
            phase: .connecting
        )
        window = TabWindowController.makeEditorWindow()
        window.isReleasedWhenClosed = false
        split = MainSplitViewController(payload: nil, sessionState: nil, adopting: workspace)
        window.contentViewController = split
        window.orderFront(nil)
    }

    func tearDown() {
        window.orderOut(nil)
        window.contentViewController = nil
        workspace.teardown()
    }
}

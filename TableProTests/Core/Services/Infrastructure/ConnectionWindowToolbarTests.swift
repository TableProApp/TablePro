//
//  ConnectionWindowToolbarTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Connection window toolbar", .serialized)
@MainActor
struct ConnectionWindowToolbarTests {
    private static let pinnedWindowSize = CGSize(width: 1_512, height: 861)

    private static let buttonActions: [(NSToolbarItem.Identifier, String)] = [
        (.toggleSidebar, "toggleSidebar:"),
        (MainWindowToolbar.connection, "performOpenConnectionSwitcher:"),
        (MainWindowToolbar.refresh, "performRefresh:"),
        (MainWindowToolbar.saveChanges, "performSaveChanges:"),
        (MainWindowToolbar.inspector, "toggleInspector:"),
    ]

    @Test("The default toolbar draws its controls in the titlebar and carries no mode control")
    func defaultToolbarDrawsItsControls() throws {
        let fixture = try makeFixture(named: "Default toolbar")
        defer { fixture.tearDown() }
        let toolbar = try #require(fixture.window.toolbar)

        #expect(toolbar.items.map(\.itemIdentifier) == MainWindowToolbar.defaultItemIdentifiers)
        #expect(!toolbar.items.contains { $0 is NSToolbarItemGroup || $0.view is NSSegmentedControl })

        let drawn = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
        for (identifier, action) in Self.buttonActions {
            #expect(drawn.contains(identifier), "\(identifier.rawValue) went to the overflow menu")
            #expect(drawnControl(sending: action, in: fixture) != nil, "\(identifier.rawValue) is not in the titlebar")
        }
        for identifier in [MainWindowToolbar.actions, MainWindowToolbar.safeMode] {
            #expect(item(identifier, in: toolbar) is NSMenuToolbarItem, "\(identifier.rawValue) is not a pull-down")
            #expect(drawn.contains(identifier), "\(identifier.rawValue) went to the overflow menu")
        }

        let database = try #require(item(MainWindowToolbar.database, in: toolbar))
        if #available(macOS 15.0, *) {
            #expect(database.isHidden, "A file-based connection has no container to switch")
            #expect(!drawn.contains(MainWindowToolbar.database))
            #expect(toolbar.items.filter(\.isHidden).map(\.itemIdentifier) == [MainWindowToolbar.database])
        } else {
            #expect(drawn.contains(MainWindowToolbar.database), "Below macOS 15 the container capsule stands")
        }
    }

    @available(macOS 15.0, *)
    @Test("Refresh leaves the toolbar on a Create Table tab, and the commit control takes its verb")
    func refreshLeavesTheToolbarOnACreateTableTab() async throws {
        let fixture = try makeFixture(named: "Create table toolbar")
        defer { fixture.tearDown() }
        let toolbar = try #require(fixture.window.toolbar)
        let refresh = try #require(item(MainWindowToolbar.refresh, in: toolbar))
        let commit = try #require(item(MainWindowToolbar.saveChanges, in: toolbar))

        fixture.workspace.open(EditorTabPayload(
            connectionId: fixture.workspace.connectionId,
            tabType: .table,
            tableName: "users"
        ))
        #expect(
            await settle(fixture) { fixture.toolbarOwner.currentVisibilityKey().tabKind == .table },
            "The toolbar never followed the table tab"
        )
        #expect(!refresh.isHidden, "A table tab shows Refresh, or its absence below would prove nothing")
        #expect(commit.label == String(localized: "Save Changes"))

        #expect(drawnControl(sending: "performRefresh:", in: fixture) != nil)

        fixture.workspace.open(EditorTabPayload(connectionId: fixture.workspace.connectionId, tabType: .createTable))
        #expect(
            await settle(fixture) { refresh.isHidden && drawnControl(sending: "performRefresh:", in: fixture) == nil },
            "An unsaved definition has nothing to reload, so Refresh leaves the titlebar"
        )
        #expect(commit.label == String(localized: "Create Table"), "The commit control names the tab's verb")
        #expect(drawnControl(sending: "performSaveChanges:", in: fixture) != nil)
    }

    private func makeFixture(named name: String) throws -> OffscreenConnectionWindow {
        let fixture = try OffscreenConnectionWindow(
            size: Self.pinnedWindowSize,
            connectedTo: TestFixtures.makeConnection(name: name, type: .sqlite)
        )
        #expect(fixture.window.frame.size == Self.pinnedWindowSize)
        #expect(fixture.toolbarOwner.coordinator === fixture.workspace.sessionState?.coordinator)
        return fixture
    }

    private func item(_ identifier: NSToolbarItem.Identifier, in toolbar: NSToolbar) -> NSToolbarItem? {
        toolbar.items.first { $0.itemIdentifier == identifier }
    }

    private func drawnControl(sending action: String, in fixture: OffscreenConnectionWindow) -> NSControl? {
        guard let frame = fixture.themeFrame else { return nil }
        let bounds = fixture.window.frame.size
        return Self.firstControl(in: frame) { control in
            guard control.action.map(NSStringFromSelector) == action,
                  !control.isHiddenOrHasHiddenAncestor else { return false }
            let placed = control.convert(control.bounds, to: nil)
            return placed.minX >= 0 && placed.maxX <= bounds.width && placed.maxY <= bounds.height
        }
    }

    private static func firstControl(in view: NSView, where matches: (NSControl) -> Bool) -> NSControl? {
        if let control = view as? NSControl, matches(control) { return control }
        for subview in view.subviews {
            if let found = firstControl(in: subview, where: matches) { return found }
        }
        return nil
    }

    private func settle(_ fixture: OffscreenConnectionWindow, until condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 150 {
            fixture.window.layoutIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

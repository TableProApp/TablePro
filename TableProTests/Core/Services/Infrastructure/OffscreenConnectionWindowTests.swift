//
//  OffscreenConnectionWindowTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Offscreen connection window", .serialized)
@MainActor
internal struct OffscreenConnectionWindowTests {
    private static let size = CGSize(width: 1_200, height: 800)

    @Test("Only the fixture's own toolbar reaches the window, and it follows the connection the window hosts")
    func toolbarIsTheFixturesOwnAndFollowsTheConnection() throws {
        let arrivals = ToolbarArrivals()
        let observer = NotificationCenter.default.addObserver(
            forName: NSToolbar.willAddItemNotification,
            object: nil,
            queue: nil
        ) { notification in
            let identifier = (notification.object as? NSToolbar)?.identifier
            MainActor.assumeIsolated { arrivals.identifiers.insert(identifier) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let fixture = try OffscreenConnectionWindow(
            size: Self.size,
            connectedTo: TestFixtures.makeConnection(name: "Fixture toolbar", type: .mysql)
        )
        defer { fixture.tearDown() }

        let coordinator = try #require(fixture.workspace.sessionState?.coordinator)
        let toolbar = try #require(fixture.window.toolbar)
        #expect(
            arrivals.identifiers == [toolbar.identifier],
            "Toolbars that reached the window: \(arrivals.identifiers)"
        )
        #expect(fixture.split.toolbarOwner === fixture.toolbarOwner)
        #expect(toolbar === fixture.toolbarOwner.managedToolbar)
        #expect(toolbar.identifier != MainWindowToolbar.toolbarIdentifier)
        #expect(!toolbar.autosavesConfiguration)
        #expect(fixture.toolbarOwner.coordinator === coordinator)
    }

    @Test("The fixture's window names no autosave record, so nothing in it can write one")
    func windowNamesNoAutosaveRecord() throws {
        let fixture = try OffscreenConnectionWindow(
            size: Self.size,
            connectedTo: TestFixtures.makeConnection(name: "Fixture autosave", type: .mysql)
        )
        defer { fixture.tearDown() }

        let frame = try #require(fixture.themeFrame)
        let splitViews = Self.views(NSSplitView.self, in: frame)
        let named = Self.autosaveNames(of: splitViews) { $0.autosaveName }
            + Self.autosaveNames(of: Self.views(NSTableView.self, in: frame)) { $0.autosaveName }
        #expect(splitViews.count > 1, "The window mounted no nested split view, so the check below proves nothing")
        #expect(named.isEmpty, "Autosave records the window would write: \(named)")
        #expect(TabWindowController.frameAutosaveName == nil)
        #expect(fixture.window.toolbar?.autosavesConfiguration == false)
    }

    @Test("The fixture leaves no record of its connection in the app's defaults or recovery list")
    func fixtureLeavesTheAppsOwnStateAlone() async throws {
        let connection = TestFixtures.makeConnection(name: "Fixture isolation", type: .mysql)

        let fixture = try OffscreenConnectionWindow(size: Self.size, connectedTo: connection)
        let coordinator = try #require(fixture.workspace.sessionState?.coordinator)
        #expect(coordinator.isActivated, "Only an activated coordinator puts its connection on the recovery list")
        #expect(
            !LastOpenConnectionsStorage.shared.load().contains(connection.id),
            "The fixture's connection reached the user's recovery list"
        )
        fixture.setInspectorOpen(true)
        fixture.setInspectorOpen(false)
        await Self.letDeferredAutosavesLand()
        fixture.tearDown()
        await Self.letDeferredAutosavesLand()

        #expect(Self.appDefaultsKeys(naming: connection.id).isEmpty)
    }

    private static func letDeferredAutosavesLand() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    private static func appDefaultsKeys(naming connectionId: UUID) -> [String] {
        let domainName = Bundle.main.bundleIdentifier ?? ""
        let domain = AppStorageEnvironment.shared.defaults.persistentDomain(forName: domainName) ?? [:]
        return domain.keys.filter { $0.contains(connectionId.uuidString) }.sorted()
    }

    private static func autosaveNames<Kind>(of views: [Kind], _ name: (Kind) -> String?) -> [String] {
        views.compactMap(name).filter { !$0.isEmpty }
    }

    private static func views<Kind: NSView>(_ kind: Kind.Type, in view: NSView) -> [Kind] {
        let own = (view as? Kind).map { [$0] } ?? []
        return own + view.subviews.flatMap { views(kind, in: $0) }
    }
}

@MainActor
private final class ToolbarArrivals {
    var identifiers: Set<NSToolbar.Identifier?> = []
}

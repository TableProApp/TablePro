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
struct OffscreenConnectionWindowTests {
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

    @Test("Building, driving and tearing down the fixture writes neither the app's toolbar nor its recovery list")
    func fixtureLeavesTheAppsOwnStateAlone() throws {
        let connection = TestFixtures.makeConnection(name: "Fixture isolation", type: .mysql)
        let toolbarRecord = Self.appToolbarRecord()

        let fixture = try OffscreenConnectionWindow(size: Self.size, connectedTo: connection)
        let coordinator = try #require(fixture.workspace.sessionState?.coordinator)
        #expect(coordinator.isActivated, "Only an activated coordinator puts its connection on the recovery list")
        #expect(
            !LastOpenConnectionsStorage.shared.load().contains(connection.id),
            "The fixture's connection reached the user's recovery list"
        )
        fixture.setInspectorOpen(true)
        fixture.setInspectorOpen(false)
        fixture.tearDown()

        #expect(Self.appToolbarRecord() == toolbarRecord, "The fixture wrote the app's own toolbar configuration")
        #expect(Self.appDefaultsKeys(naming: connection.id).isEmpty)
    }

    private static func appDefaults() -> [String: Any] {
        let domainName = Bundle.main.bundleIdentifier ?? ""
        return AppStorageEnvironment.shared.defaults.persistentDomain(forName: domainName) ?? [:]
    }

    private static func appToolbarRecord() -> NSDictionary? {
        appDefaults()["NSToolbar Configuration \(MainWindowToolbar.toolbarIdentifier)"] as? NSDictionary
    }

    private static func appDefaultsKeys(naming connectionId: UUID) -> [String] {
        appDefaults().keys.filter { $0.contains(connectionId.uuidString) }.sorted()
    }
}

@MainActor
private final class ToolbarArrivals {
    var identifiers: Set<NSToolbar.Identifier?> = []
}

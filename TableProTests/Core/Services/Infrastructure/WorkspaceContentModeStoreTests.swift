//
//  WorkspaceContentModeStoreTests.swift
//  TableProTests
//
//  The mode a connection was left in has to come back on relaunch, and a value written by a
//  newer release has to leave the window with content rather than nothing.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Workspace content mode store")
@MainActor
struct WorkspaceContentModeStoreTests {
    private static func makeStore() -> (WorkspaceContentModeStore, UserDefaults) {
        let suiteName = "com.TablePro.tests.workspaceContentMode.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("UserDefaults suite \(suiteName) could not be created")
        }
        return (WorkspaceContentModeStore(defaults: defaults), defaults)
    }

    @Test("A connection nobody has switched is in browse mode")
    func defaultsToBrowse() {
        let (store, _) = Self.makeStore()

        #expect(store.mode(connectionId: UUID()) == .browse)
    }

    @Test("Assistant mode survives a round trip")
    func assistantModeRoundTrips() {
        let (store, _) = Self.makeStore()
        let connectionId = UUID()

        store.setMode(.assistant, connectionId: connectionId)

        #expect(store.mode(connectionId: connectionId) == .assistant)
    }

    @Test("Switching back to browse clears the record rather than storing the default")
    func browseModeClearsTheRecord() {
        let (store, defaults) = Self.makeStore()
        let connectionId = UUID()
        let key = "com.TablePro.workspaceContentMode.\(connectionId.uuidString)"

        store.setMode(.assistant, connectionId: connectionId)
        store.setMode(.browse, connectionId: connectionId)

        #expect(store.mode(connectionId: connectionId) == .browse)
        #expect(defaults.string(forKey: key) == nil)
    }

    @Test("A mode this release does not know falls back to browse, not to a blank window")
    func unknownStoredValueFallsBackToBrowse() {
        let (store, defaults) = Self.makeStore()
        let connectionId = UUID()

        defaults.set("orchestrator", forKey: "com.TablePro.workspaceContentMode.\(connectionId.uuidString)")

        #expect(store.mode(connectionId: connectionId) == .browse)
    }

    @Test("Two connections keep their own modes")
    func modesAreScopedPerConnection() {
        let (store, _) = Self.makeStore()
        let assistant = UUID()
        let browse = UUID()

        store.setMode(.assistant, connectionId: assistant)

        #expect(store.mode(connectionId: assistant) == .assistant)
        #expect(store.mode(connectionId: browse) == .browse)
    }

    @Test("Removing a connection's mode takes it back to browse")
    func removingModeReturnsToBrowse() {
        let (store, _) = Self.makeStore()
        let connectionId = UUID()

        store.setMode(.assistant, connectionId: connectionId)
        store.removeMode(for: connectionId)

        #expect(store.mode(connectionId: connectionId) == .browse)
    }
}

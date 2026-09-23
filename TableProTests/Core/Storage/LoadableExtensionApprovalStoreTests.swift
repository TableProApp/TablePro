//
//  LoadableExtensionApprovalStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Loadable extension approvals")
@MainActor
struct LoadableExtensionApprovalStoreTests {
    private let defaults: UserDefaults
    private let store: LoadableExtensionApprovalStore
    private let vec = LoadableExtension(path: "/opt/homebrew/lib/vec0.dylib")
    private let spatialite = LoadableExtension(path: "/opt/homebrew/lib/mod_spatialite.dylib")

    init() throws {
        let suite = "LoadableExtensionApprovalStoreTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        store = LoadableExtensionApprovalStore(defaults: defaults)
    }

    @Test("Nothing is approved until someone approves it")
    func nothingApprovedByDefault() {
        #expect(store.unapproved([vec, spatialite], for: UUID()) == [vec, spatialite])
    }

    @Test("Approval covers the files approved, for that connection only")
    func approvalIsPerConnection() {
        let connection = UUID()
        let imported = UUID()
        store.approve([vec], for: connection)
        #expect(store.unapproved([vec, spatialite], for: connection) == [spatialite])
        #expect(store.unapproved([vec], for: imported) == [vec])
    }

    @Test("A different entry point is a different extension")
    func entryPointIsPartOfTheApproval() {
        let connection = UUID()
        store.approve([vec], for: connection)
        let other = LoadableExtension(path: vec.path, entryPoint: "sqlite3_vec_numpy_init")
        #expect(store.unapproved([other], for: connection) == [other])
    }

    @Test("A tilde path and its expanded form are the same file")
    func tildeMatchesExpandedPath() {
        let connection = UUID()
        store.approve([LoadableExtension(path: "~/lib/vec0.dylib")], for: connection)
        let expanded = LoadableExtension(path: NSHomeDirectory() + "/lib/vec0.dylib")
        #expect(store.unapproved([expanded], for: connection).isEmpty)
    }

    @Test("Revoking forgets a connection's approvals and keeps the others")
    func revokeIsScoped() {
        let deleted = UUID()
        let kept = UUID()
        store.approve([vec], for: deleted)
        store.approve([vec], for: kept)
        store.revoke(for: [deleted])
        #expect(store.unapproved([vec], for: deleted) == [vec])
        #expect(store.unapproved([vec], for: kept).isEmpty)
    }

    @Test("A duplicate takes the approvals of the connection it copies")
    func copyCarriesApprovals() {
        let source = UUID()
        let duplicate = UUID()
        store.approve([vec, spatialite], for: source)
        store.copyApprovals(from: source, to: duplicate)
        #expect(store.unapproved([vec, spatialite], for: duplicate).isEmpty)
    }

    @Test("Approvals persist in the defaults they were written to")
    func persists() {
        let connection = UUID()
        store.approve([vec], for: connection)
        let reopened = LoadableExtensionApprovalStore(defaults: defaults)
        #expect(reopened.unapproved([vec], for: connection).isEmpty)
    }
}

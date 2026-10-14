//
//  StandardDomainIsolationTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing
@testable import TablePro

// The Unit plan sandboxes the host, so app state that still lands in the standard domain fails here.
@MainActor
struct StandardDomainIsolationTests {
    private let appDefaults = AppStorageEnvironment.shared.defaults

    @Test("Quick switcher frecency built with its defaults writes to the app's store")
    func frecencyFollowsTheStorageEnvironment() {
        let connectionId = UUID()
        let store = QuickSwitcherFrecencyStore(connectionId: connectionId)
        defer { store.clearHistory() }

        store.recordAccess(itemId: "table_users")

        let reader = QuickSwitcherFrecencyStore(connectionId: connectionId, defaults: appDefaults)
        #expect(reader.recentItemIds() == ["table_users"])
    }

    @Test("Recent tables built with their defaults write to the app's store")
    func recentTablesFollowTheStorageEnvironment() {
        let connectionId = UUID()
        let store = RecentTablesStore()
        defer { store.removeEntries(for: connectionId) }

        store.record(connectionId: connectionId, database: "db", schema: nil, name: "users", isView: false, objectType: nil)

        let reader = RecentTablesStore(defaults: appDefaults)
        #expect(reader.entries(connectionId: connectionId).map(\.name) == ["users"])
    }

    @Test("The registry client built with its defaults migrates the app's store")
    func registryClientFollowsTheStorageEnvironment() {
        let legacyKey = "registryETag"
        appDefaults.set("stale", forKey: legacyKey)
        defer { appDefaults.removeObject(forKey: legacyKey) }
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-store-defaults-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("registry-manifest.json")

        _ = RegistryClient(manifestCacheURL: cacheURL)

        #expect(appDefaults.object(forKey: legacyKey) == nil)
    }

    @Test("The privilege scope outline saves its columns only under an autosave name")
    func scopeOutlineSavesColumnsOnlyUnderAName() throws {
        let viewModel = UsersRolesViewModel(connectionId: UUID(), databaseType: .postgresql)
        let scrollView = PrivilegeScopeOutlineView.makeScrollView(
            coordinator: PrivilegeScopeOutlineCoordinator(viewModel: viewModel)
        )
        let outline = try #require(scrollView.documentView as? NSOutlineView)

        #expect(outline.autosaveTableColumns == (outline.autosaveName != nil))
    }
}

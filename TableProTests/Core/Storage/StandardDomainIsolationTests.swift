//
//  StandardDomainIsolationTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TableProUtilities
import Testing
@testable import TablePro

// The Unit plan sandboxes the host, so app state that still lands in the standard domain fails here.
@MainActor
struct StandardDomainIsolationTests {
    private let appDefaults = AppStorageEnvironment.shared.defaults

    @Test("A table opened from the sidebar records its frecency in the app's store")
    func sidebarFrecencyFollowsTheStorageEnvironment() {
        let state = SharedSidebarState()
        let reader = QuickSwitcherFrecencyStore(connectionId: state.connectionId, defaults: appDefaults)
        defer {
            reader.clearHistory()
            RecentTablesStore.shared.removeEntries(for: state.connectionId)
        }

        state.recordTableOpen(
            database: nil, schema: nil, name: "users", isView: false, objectType: nil,
            isPreview: false, connectionSwitchesDatabases: false
        )

        let key = SharedSidebarState.tableFrecencyKey(
            database: nil, schema: nil, name: "users", connectionSwitchesDatabases: false
        )
        #expect(reader.recentItemIds() == [key])
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

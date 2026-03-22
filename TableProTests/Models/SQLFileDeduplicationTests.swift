//
//  SQLFileDeduplicationTests.swift
//  TableProTests
//
//  Tests for SQL file deduplication when opening .sql files in TablePro.
//  Validates sourceFileURL tracking on QueryTab, EditorTabPayload, and PersistedTab,
//  and deduplication logic in QueryTabManager.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

// MARK: - QueryTab sourceFileURL Property Tests

@Suite("QueryTab sourceFileURL")
struct QueryTabSourceFileURLTests {
    @Test("QueryTab stores sourceFileURL when set")
    func storesSourceFileURL() {
        var tab = QueryTab(title: "Test", tabType: .query)
        let url = URL(fileURLWithPath: "/tmp/test.sql")
        tab.sourceFileURL = url

        #expect(tab.sourceFileURL == url)
    }

    @Test("QueryTab sourceFileURL defaults to nil")
    func defaultsToNil() {
        let tab = QueryTab(title: "Test", tabType: .query)

        #expect(tab.sourceFileURL == nil)
    }
}

// MARK: - QueryTabManager Deduplication Tests

@Suite("QueryTabManager SQL file deduplication")
struct QueryTabManagerDeduplicationTests {
    @Test("addTab with sourceFileURL creates new tab when no duplicate exists")
    @MainActor
    func createsNewTabWithSourceFileURL() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.sql")

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.sourceFileURL == url)
    }

    @Test("addTab with same sourceFileURL selects existing tab instead of creating duplicate")
    @MainActor
    func deduplicatesSameSourceFileURL() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.sql")

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)
        tabManager.addTab(initialQuery: "SELECT 2", sourceFileURL: url)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTabId == tabManager.tabs.first?.id)
    }

    @Test("addTab with different sourceFileURL creates separate tabs")
    @MainActor
    func createsSeparateTabsForDifferentFiles() {
        let tabManager = QueryTabManager()
        let urlA = URL(fileURLWithPath: "/tmp/a.sql")
        let urlB = URL(fileURLWithPath: "/tmp/b.sql")

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: urlA)
        tabManager.addTab(initialQuery: "SELECT 2", sourceFileURL: urlB)

        #expect(tabManager.tabs.count == 2)
    }

    @Test("addTab without sourceFileURL always creates new tab")
    @MainActor
    func noDedupWhenSourceFileURLIsNil() {
        let tabManager = QueryTabManager()

        tabManager.addTab(initialQuery: "SELECT 1")
        tabManager.addTab(initialQuery: "SELECT 2")

        #expect(tabManager.tabs.count == 2)
    }

    @Test("addTab with sourceFileURL updates query content of existing tab")
    @MainActor
    func updatesQueryContentOnDuplicate() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.sql")

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)
        tabManager.addTab(initialQuery: "SELECT 2", sourceFileURL: url)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.query == "SELECT 2")
    }
}

// MARK: - EditorTabPayload sourceFileURL Tests

@Suite("EditorTabPayload sourceFileURL")
struct EditorTabPayloadSourceFileURLTests {
    @Test("EditorTabPayload carries sourceFileURL")
    func carriesSourceFileURL() {
        let url = URL(fileURLWithPath: "/tmp/test.sql")
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            initialQuery: "SELECT 1",
            sourceFileURL: url
        )

        #expect(payload.sourceFileURL == url)
    }

    @Test("EditorTabPayload isConnectionOnly is true even with sourceFileURL")
    func isConnectionOnlyUnaffectedBySourceFileURL() {
        let url = URL(fileURLWithPath: "/tmp/test.sql")
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            sourceFileURL: url
        )

        #expect(payload.isConnectionOnly == true)
    }
}

// MARK: - SessionStateFactory sourceFileURL Propagation Tests

@Suite("SessionStateFactory sourceFileURL propagation")
struct SessionStateFactorySourceFileURLTests {
    @Test("SessionStateFactory propagates sourceFileURL to tab")
    @MainActor
    func propagatesSourceFileURL() {
        let conn = TestFixtures.makeConnection()
        let url = URL(fileURLWithPath: "/tmp/test.sql")
        let payload = EditorTabPayload(
            connectionId: conn.id,
            tabType: .query,
            initialQuery: "SELECT 1",
            sourceFileURL: url
        )

        let state = SessionStateFactory.create(connection: conn, payload: payload)

        #expect(state.tabManager.tabs.count == 1)
        #expect(state.tabManager.tabs.first?.sourceFileURL == url)
    }
}

// MARK: - PersistedTab sourceFileURL Round-Trip Tests

@Suite("PersistedTab sourceFileURL persistence")
struct PersistedTabSourceFileURLTests {
    @Test("PersistedTab preserves sourceFileURL through encode/decode")
    func roundTripsSourceFileURL() throws {
        let url = URL(fileURLWithPath: "/tmp/test.sql")
        let original = PersistedTab(
            id: UUID(),
            title: "Test",
            query: "SELECT 1",
            tabType: .query,
            tableName: nil,
            sourceFileURL: url
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: data)

        #expect(decoded.sourceFileURL == url)
    }

    @Test("PersistedTab without sourceFileURL decodes as nil")
    func decodesNilSourceFileURL() throws {
        let original = PersistedTab(
            id: UUID(),
            title: "Test",
            query: "SELECT 1",
            tabType: .query,
            tableName: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: data)

        #expect(decoded.sourceFileURL == nil)
    }
}

// MARK: - WindowLifecycleMonitor Source File Tracking Tests

@Suite("WindowLifecycleMonitor source file tracking")
@MainActor
struct WindowLifecycleMonitorSourceFileTests {
    @Test("window(forSourceFile:) returns nil for unregistered URL")
    func unregisteredURLReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/unknown.sql")
        #expect(WindowLifecycleMonitor.shared.window(forSourceFile: url) == nil)
    }

    @Test("registerSourceFile and window(forSourceFile:) round-trip when window is alive")
    func registerAndFindSourceFile() {
        let url = URL(fileURLWithPath: "/tmp/registered.sql")
        let windowId = UUID()
        let window = NSWindow()

        WindowLifecycleMonitor.shared.register(
            window: window,
            connectionId: UUID(),
            windowId: windowId
        )
        WindowLifecycleMonitor.shared.registerSourceFile(url, windowId: windowId)

        #expect(WindowLifecycleMonitor.shared.window(forSourceFile: url) === window)

        WindowLifecycleMonitor.shared.unregisterSourceFile(url)
        WindowLifecycleMonitor.shared.unregisterWindow(for: windowId)
    }

    @Test("unregisterSourceFiles(for:) removes all files for a window")
    func unregisterAllFilesForWindow() {
        let url1 = URL(fileURLWithPath: "/tmp/file1.sql")
        let url2 = URL(fileURLWithPath: "/tmp/file2.sql")
        let windowId = UUID()
        let window = NSWindow()

        WindowLifecycleMonitor.shared.register(
            window: window,
            connectionId: UUID(),
            windowId: windowId
        )
        WindowLifecycleMonitor.shared.registerSourceFile(url1, windowId: windowId)
        WindowLifecycleMonitor.shared.registerSourceFile(url2, windowId: windowId)

        WindowLifecycleMonitor.shared.unregisterSourceFiles(for: windowId)

        #expect(WindowLifecycleMonitor.shared.window(forSourceFile: url1) == nil)
        #expect(WindowLifecycleMonitor.shared.window(forSourceFile: url2) == nil)

        WindowLifecycleMonitor.shared.unregisterWindow(for: windowId)
    }

    @Test("window(forSourceFile:) returns nil after window is unregistered")
    func returnsNilAfterWindowUnregistered() {
        let url = URL(fileURLWithPath: "/tmp/closed.sql")
        let windowId = UUID()
        let window = NSWindow()

        WindowLifecycleMonitor.shared.register(
            window: window,
            connectionId: UUID(),
            windowId: windowId
        )
        WindowLifecycleMonitor.shared.registerSourceFile(url, windowId: windowId)
        WindowLifecycleMonitor.shared.unregisterWindow(for: windowId)

        #expect(WindowLifecycleMonitor.shared.window(forSourceFile: url) == nil)
    }
}

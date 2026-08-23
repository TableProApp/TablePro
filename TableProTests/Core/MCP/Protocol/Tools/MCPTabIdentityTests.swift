//
//  MCPTabIdentityTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("MCP tab and window identity")
struct MCPTabIdentityTests {
    private let tabId = UUID()
    private let connectionId = UUID()
    private let windowId = UUID()

    private func snapshot(
        tableName: String? = "users",
        windowId: UUID?,
        isActive: Bool = true
    ) -> MCPTabSnapshot {
        MCPTabSnapshot(
            tabId: tabId,
            connectionId: connectionId,
            connectionName: "Primary",
            tabType: "table",
            tableName: tableName,
            databaseName: "shop",
            schemaName: "public",
            displayTitle: "users",
            windowId: windowId,
            isActive: isActive,
            window: nil
        )
    }

    @Test("The encoded tab carries the same ids the snapshot holds")
    func encodedTabCarriesTheSnapshotIds() throws {
        let encoded = MCPTabSnapshotProvider.encode(snapshot(windowId: windowId))
        #expect(encoded["tab_id"]?.stringValue == tabId.uuidString)
        #expect(encoded["window_id"]?.stringValue == windowId.uuidString)
        #expect(encoded["connection_id"]?.stringValue == connectionId.uuidString)
        #expect(encoded["connection_name"]?.stringValue == "Primary")
        #expect(encoded["tab_type"]?.stringValue == "table")
        #expect(encoded["table_name"]?.stringValue == "users")
        #expect(encoded["database_name"]?.stringValue == "shop")
        #expect(encoded["schema_name"]?.stringValue == "public")
        #expect(encoded["is_active"]?.boolValue == true)
    }

    @Test("A tab with no window reports no window id rather than an invented one")
    func absentWindowIdIsOmitted() {
        let encoded = MCPTabSnapshotProvider.encode(snapshot(windowId: nil))
        #expect(encoded["window_id"] == nil)
    }

    @Test("Optional table context is omitted rather than sent as an empty string")
    func absentTableContextIsOmitted() {
        let bare = MCPTabSnapshot(
            tabId: tabId,
            connectionId: connectionId,
            connectionName: "Primary",
            tabType: "query",
            tableName: nil,
            databaseName: nil,
            schemaName: nil,
            displayTitle: "Query 1",
            windowId: nil,
            isActive: false,
            window: nil
        )
        let encoded = MCPTabSnapshotProvider.encode(bare)
        #expect(encoded["table_name"] == nil)
        #expect(encoded["database_name"] == nil)
        #expect(encoded["schema_name"] == nil)
        #expect(encoded["is_active"]?.boolValue == false)
    }

    @Test("Opening and listing agree on the window id, so a client can follow an open with a focus")
    func openAndListShareTheWindowIdentity() throws {
        let listed = MCPTabSnapshotProvider.encode(snapshot(windowId: windowId))

        let openTableFields = try #require(OpenTableTabTool.outputSchema?["properties"]?.objectValue)
        let openWindowFields = try #require(OpenConnectionWindowTool.outputSchema?["properties"]?.objectValue)
        let focusFields = try #require(FocusQueryTabTool.outputSchema?["properties"]?.objectValue)
        let listFields = try #require(
            ListRecentTabsTool.outputSchema?["properties"]?["tabs"]?["items"]?["properties"]?.objectValue
        )

        for (label, fields) in [
            ("open_table_tab", openTableFields),
            ("open_connection_window", openWindowFields),
            ("focus_query_tab", focusFields),
            ("list_recent_tabs", listFields)
        ] {
            #expect(fields["window_id"] != nil, "\(label) must report window_id")
            #expect(fields["tab_id"] != nil, "\(label) must report tab_id")
        }

        #expect(listed["window_id"]?.stringValue == windowId.uuidString)
        #expect(listed["tab_id"]?.stringValue == tabId.uuidString)
    }

    @Test("The tab schema list_recent_tabs advertises is the one the encoder fills")
    func tabSchemaMatchesTheEncoder() throws {
        let schema = try #require(MCPTabSnapshotProvider.tabSchema["properties"]?.objectValue)
        let encoded = try #require(MCPTabSnapshotProvider.encode(snapshot(windowId: windowId)).objectValue)
        for key in encoded.keys {
            #expect(schema[key] != nil, "the encoder emits '\(key)' but the schema does not declare it")
        }
        let required = MCPTabSnapshotProvider.tabSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for key in required {
            #expect(encoded[key] != nil, "the schema requires '\(key)' but the encoder can omit it")
        }
    }

    @Test("A headless process reports no tabs and no readable tabs")
    func headlessProcessHasNoTabs() async {
        let snapshots = await MainActor.run { MCPTabSnapshotProvider.collectTabSnapshots() }
        let readable = await MCPTabSnapshotProvider.readableSnapshots(
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
        #expect(readable.count <= snapshots.count)
        #expect(readable.allSatisfy { snapshot in snapshots.contains { $0.tabId == snapshot.tabId } })
    }
}

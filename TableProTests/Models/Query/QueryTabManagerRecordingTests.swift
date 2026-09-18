import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("QueryTabManager.onTableOpened")
@MainActor
struct QueryTabManagerRecordingTests {
    private struct Opened: Equatable {
        let name: String
        let schema: String?
        let database: String
        let isView: Bool
        let objectType: TableInfo.TableType?
        let isPreview: Bool
    }

    private func recorder() -> (QueryTabManager, () -> [Opened]) {
        let manager = QueryTabManager()
        var opened: [Opened] = []
        manager.onTableOpened = { name, schema, database, isView, objectType, isPreview in
            opened.append(
                Opened(
                    name: name, schema: schema, database: database,
                    isView: isView, objectType: objectType, isPreview: isPreview
                )
            )
        }
        return (manager, { opened })
    }

    @Test("addTableTab reports a committed open")
    func addTableTabReportsCommitted() throws {
        let (manager, opened) = recorder()
        try manager.addTableTab(tableName: "orders", databaseName: "shop", schemaName: "sales")
        #expect(
            opened() == [
                Opened(
                    name: "orders", schema: "sales", database: "shop",
                    isView: false, objectType: nil, isPreview: false
                ),
            ]
        )
    }

    @Test("addTableTab carries the view flag")
    func addTableTabCarriesViewFlag() throws {
        let (manager, opened) = recorder()
        try manager.addTableTab(tableName: "orders_view", databaseName: "shop", schemaName: "sales", isView: true)
        #expect(opened().first?.isView == true)
    }

    /// `isView` says only that the object is not a table, which made whoever records the open call a
    /// MariaDB sequence a view: the Recent row then offered Drop View and issued `DROP VIEW`, which
    /// the server refuses with ERROR 4092.
    @Test("addTableTab carries the object's kind")
    func addTableTabCarriesObjectType() throws {
        let (manager, opened) = recorder()
        try manager.addTableTab(
            tableName: "order_ids", databaseName: "app", isView: true, objectType: .sequence
        )
        #expect(opened().first?.objectType == .sequence)
    }

    @Test("replaceTabContent carries the object's kind")
    func replaceTabContentCarriesObjectType() throws {
        let (manager, opened) = recorder()
        try manager.addTableTab(tableName: "seed", databaseName: "app")
        _ = try manager.replaceTabContent(
            tableName: "order_ids", isView: true, objectType: .sequence, databaseName: "app"
        )
        #expect(opened().last?.objectType == .sequence)
    }

    @Test("addTableTab with isPreview reports the open as a preview")
    func previewReportsAsPreview() throws {
        let (manager, opened) = recorder()
        try manager.addTableTab(tableName: "orders", databaseName: "shop", schemaName: "sales", isPreview: true)
        #expect(
            opened() == [
                Opened(
                    name: "orders", schema: "sales", database: "shop",
                    isView: false, objectType: nil, isPreview: true
                ),
            ]
        )
    }

    @Test("Re-opening an already-open table reports it again")
    func reopenReportsAgain() throws {
        let (manager, opened) = recorder()
        try manager.addTableTab(tableName: "orders", databaseName: "shop", schemaName: "sales")
        try manager.addTableTab(tableName: "orders", databaseName: "shop", schemaName: "sales")
        #expect(opened().count == 2)
    }

    @Test("adoptResolvedSchema reports the schema once and never a second open")
    func adoptResolvedSchemaReportsOnce() throws {
        struct Resolved: Equatable {
            let name: String
            let database: String
            let schema: String
        }
        let (manager, opened) = recorder()
        var resolved: [Resolved] = []
        manager.onTableSchemaResolved = { name, database, schema in
            resolved.append(Resolved(name: name, database: database, schema: schema))
        }
        try manager.addTableTab(tableName: "orders", databaseName: "shop")

        manager.adoptResolvedSchema("sales", at: 0)

        #expect(resolved == [Resolved(name: "orders", database: "shop", schema: "sales")])
        #expect(manager.tabs.first?.tableContext.schemaName == "sales")
        #expect(opened().count == 1)
    }

    @Test("replaceTabContent reports its preview flag")
    func replaceReportsPreviewFlag() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "seed", databaseName: "shop")
        var opened: [Opened] = []
        manager.onTableOpened = { name, schema, database, isView, objectType, isPreview in
            opened.append(
                Opened(
                    name: name, schema: schema, database: database,
                    isView: isView, objectType: objectType, isPreview: isPreview
                )
            )
        }
        _ = try manager.replaceTabContent(
            tableName: "orders", isView: true, databaseName: "shop", schemaName: "sales", isPreview: true
        )
        #expect(
            opened == [
                Opened(
                    name: "orders", schema: "sales", database: "shop",
                    isView: true, objectType: nil, isPreview: true
                ),
            ]
        )
    }
}

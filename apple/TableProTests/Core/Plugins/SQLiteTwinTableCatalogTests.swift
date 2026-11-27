import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

// SQLite keeps apart two table names that differ only in Unicode form, so the bundled driver answers with both.
@MainActor
struct SQLiteTwinTableCatalogTests {
    private static let composed = CatalogName(TwinNames.composed)
    private static let decomposed = CatalogName(TwinNames.decomposed)

    private static func openTwinFile() async throws -> (adapter: PluginDriverAdapter, driver: any PluginDatabaseDriver, path: String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("twins-\(UUID().uuidString).sqlite").path
        let plugin = try BundledPlugin.driver("SQLiteDriver").init()
        let driver = plugin.createDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: path
        ))
        try await driver.connect()
        for statement in [
            "CREATE TABLE \"\(TwinNames.composed)\" (id INTEGER PRIMARY KEY, a TEXT)",
            "CREATE TABLE \"\(TwinNames.decomposed)\" (id INTEGER PRIMARY KEY, b TEXT)",
            "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES \"\(TwinNames.decomposed)\"(id))",
            "CREATE INDEX composed_a ON \"\(TwinNames.composed)\" (a)",
            "CREATE INDEX decomposed_b ON \"\(TwinNames.decomposed)\" (b)"
        ] {
            _ = try await driver.execute(query: statement)
        }
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .sqlite), pluginDriver: driver)
        return (adapter, driver, path)
    }

    @Test("The schema-wide reads of a SQLite file keep each twin table's own columns and keys")
    func sharedReadsKeepTwinsApart() async throws {
        let file = try await Self.openTwinFile()
        defer {
            file.driver.disconnect()
            try? FileManager.default.removeItem(atPath: file.path)
        }

        let columns = try await file.adapter.fetchAllColumns(schema: nil)
        let keys = try await file.adapter.fetchAllForeignKeys(schema: nil)

        #expect(columns[Self.composed]?.map(\.name) == ["id", "a"])
        #expect(columns[Self.decomposed]?.map(\.name) == ["id", "b"])
        #expect(keys["child"]?.first.map { CatalogName($0.referencedTable) } == Self.decomposed)

        let graph = ERDiagramGraphBuilder.build(allColumns: columns, allForeignKeys: keys)
        #expect(graph.nodes.count == 3)
        #expect(graph.edges.first.flatMap { graph.nodeId(of: $0.toTable) } == graph.nodeIndex[Self.decomposed])

        let joins = JoinGraph(columns: columns.mapValues { $0.map(\.name) }, foreignKeys: keys, isLocal: { _ in true })
        #expect(joins.relationships(between: "child", and: Self.decomposed).count == 1)
        #expect(joins.relationships(between: "child", and: Self.composed).isEmpty)
    }

    @Test("Each twin table of a SQLite file lists and compares its own indexes")
    func indexesStayWithTheirTwin() async throws {
        let file = try await Self.openTwinFile()
        defer {
            file.driver.disconnect()
            try? FileManager.default.removeItem(atPath: file.path)
        }

        let entries = try await MCPConnectionBridge.indexEntries(using: file.adapter, schema: nil, table: nil)
        let listed = entries.compactMap { entry -> (CatalogName, [String])? in
            guard let table = entry["table"]?.stringValue else { return nil }
            return (CatalogName(table), entry["indexes"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        }
        let reads = try await CompareMetadataService.read(
            tables: try await file.driver.fetchTables(schema: nil), schema: nil, profile: .structure,
            narrowed: false, databaseType: .sqlite, indexedKinds: [], using: file.driver
        )
        let compared = Dictionary(uniqueKeysWithValues: reads.map { (CatalogName($0.table.name), $0.indexes.map(\.name)) })

        #expect(Dictionary(uniqueKeysWithValues: listed)[Self.composed] == ["composed_a"])
        #expect(Dictionary(uniqueKeysWithValues: listed)[Self.decomposed] == ["decomposed_b"])
        #expect(compared[Self.composed] == ["composed_a"])
        #expect(compared[Self.decomposed] == ["decomposed_b"])
    }
}

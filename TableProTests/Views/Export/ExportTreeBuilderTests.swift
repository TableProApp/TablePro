//
//  ExportTreeBuilderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

/// The export tree's rules used to live inside `ExportDialog`, where the only way to reach them was
/// to open a real connection and click Export. These pin the ones that shipped as bugs: a schema
/// section that stayed shut over a correctly ticked row, a container listed with no objects in it,
/// and a row losing its checkboxes across the reload a format change causes.
@Suite("Export tree building")
@MainActor
struct ExportTreeBuilderTests {
    private struct FakeReader: ExportMetadataReading {
        var schemas: [String] = []
        var databases: [String] = []
        var tablesBySchema: [String: [TableInfo]] = [:]
        var flatTables: [TableInfo] = []
        var groupedTables: [String: [TableInfo]] = [:]

        func fetchSchemas() async throws -> [String] { schemas }
        func fetchDatabases() async throws -> [String] { databases }

        func fetchTables(schema: String?) async throws -> [TableInfo] {
            guard let schema else { return flatTables }
            return tablesBySchema[schema] ?? []
        }

        func fetchTablesGroupedByDatabase() async throws -> [String: [TableInfo]] { groupedTables }

        func loadObjects(request: ExportObjectLoader.Request, tables: [TableInfo]) async -> [ExportObjectItem] {
            tables.map {
                ExportObjectItem(name: $0.name, databaseName: request.containerName, kind: .table)
            }
        }

        func columnNames(table: String, schema: String?) async -> [String] { [] }
    }

    private static let schemaTypeId = "ExportTreeBuilderTestsSchemaEngine"
    private static let databaseTypeId = "ExportTreeBuilderTestsDatabaseEngine"

    private static func registerTypes() {
        for (typeId, grouping) in [
            (schemaTypeId, GroupingStrategy.bySchema),
            (databaseTypeId, GroupingStrategy.byDatabase),
        ] {
            let schema = PluginMetadataSnapshot.SchemaInfo(
                defaultSchemaName: "public",
                defaultGroupName: "main",
                tableEntityName: "Tables",
                containerEntityName: "Database",
                defaultPrimaryKeyColumn: nil,
                immutableColumns: [],
                systemDatabaseNames: [],
                systemSchemaNames: [],
                fileExtensions: [],
                databaseGroupingStrategy: grouping,
                structureColumnFields: [.name, .type]
            )
            let snapshot = PluginMetadataSnapshot(
                displayName: typeId, iconName: "cylinder", defaultPort: 1_234,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: false, primaryUrlScheme: typeId.lowercased(), parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: false, urlSchemes: [typeId.lowercased()], postConnectActions: [],
                brandColorHex: "#000000", queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                capabilities: .defaults, schema: schema, editor: .defaults, connection: .defaults
            )
            PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: typeId)
        }
    }

    private static func builder(
        typeId: String,
        preselection: ExportPreselection,
        reader: FakeReader,
        database: String = "app"
    ) -> ExportTreeBuilder {
        registerTypes()
        var connection = TestFixtures.makeConnection(database: database)
        connection.type = DatabaseType(rawValue: typeId)
        return ExportTreeBuilder(
            connection: connection,
            exportDatabaseName: database,
            preselection: preselection,
            supportedObjectKinds: [.table, .view],
            reader: reader
        )
    }

    private static func makeTable(_ name: String) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil)
    }

    @Test("A schema holding the preselected table is expanded even when it is not the default one")
    func preselectedSchemaExpands() async throws {
        let reader = FakeReader(
            schemas: ["public", "reporting"],
            tablesBySchema: ["public": [Self.makeTable("users")], "reporting": [Self.makeTable("orders")]]
        )
        let builder = Self.builder(
            typeId: Self.schemaTypeId,
            preselection: .tables(names: ["orders"], scope: .schema(database: "app", schema: "reporting")),
            reader: reader
        )

        let items = try await builder.build(priorRows: [:])
        let reporting = try #require(items.first { $0.name == "reporting" })

        #expect(reporting.isExpanded)
        #expect(reporting.objects.first { $0.name == "orders" }?.isSelected == true)
    }

    @Test("The default schema sorts first whatever the server returned")
    func defaultSchemaSortsFirst() async throws {
        let reader = FakeReader(
            schemas: ["reporting", "archive", "public"],
            tablesBySchema: [
                "public": [Self.makeTable("users")],
                "reporting": [Self.makeTable("orders")],
                "archive": [Self.makeTable("old")],
            ]
        )
        let builder = Self.builder(
            typeId: Self.schemaTypeId,
            preselection: .tables(names: [], scope: nil),
            reader: reader
        )

        let items = try await builder.build(priorRows: [:])

        #expect(items.map(\.name) == ["public", "archive", "reporting"])
    }

    @Test("A container the format can read nothing from is left out of the tree")
    func emptyContainersAreDropped() async throws {
        let reader = FakeReader(
            schemas: ["public", "empty"],
            tablesBySchema: ["public": [Self.makeTable("users")], "empty": []]
        )
        let builder = Self.builder(
            typeId: Self.schemaTypeId,
            preselection: .tables(names: [], scope: nil),
            reader: reader
        )

        let items = try await builder.build(priorRows: [:])

        #expect(items.map(\.name) == ["public"])
    }

    @Test("A reload carries each row's checkboxes over instead of re-reading the preselection")
    func priorRowsSurviveAReload() async throws {
        let reader = FakeReader(
            schemas: ["public"],
            tablesBySchema: ["public": [Self.makeTable("users"), Self.makeTable("orders")]]
        )
        let builder = Self.builder(
            typeId: Self.schemaTypeId,
            preselection: .tables(names: ["users"], scope: .schema(database: "app", schema: "public")),
            reader: reader
        )

        var first = try await builder.build(priorRows: [:])
        #expect(first.first?.objects.first { $0.name == "users" }?.isSelected == true)
        #expect(first.first?.objects.first { $0.name == "orders" }?.isSelected == false)

        first[0].objects = first[0].objects.map { object in
            var updated = object
            updated.isSelected = object.name == "orders"
            return updated
        }

        let second = try await builder.build(priorRows: ExportTreeBuilder.snapshots(of: first))
        let objects = try #require(second.first?.objects)

        #expect(objects.first { $0.name == "users" }?.isSelected == false)
        #expect(objects.first { $0.name == "orders" }?.isSelected == true)
    }

    @Test("A routine and a table sharing one name keep their own checkboxes")
    func snapshotKeyIsPerKind() {
        let table = ExportTreeBuilder.snapshotKey(container: "public", object: "audit", kind: .table)
        let routine = ExportTreeBuilder.snapshotKey(container: "public", object: "audit", kind: .routine)

        #expect(table != routine)
    }

    @Test("The connection's own database sorts first on a database-grouped engine")
    func currentDatabaseSortsFirst() async throws {
        let reader = FakeReader(
            databases: ["archive", "app", "staging"],
            groupedTables: [
                "app": [Self.makeTable("users")],
                "archive": [Self.makeTable("old")],
                "staging": [Self.makeTable("draft")],
            ]
        )
        let builder = Self.builder(
            typeId: Self.databaseTypeId,
            preselection: .tables(names: [], scope: nil),
            reader: reader
        )

        let items = try await builder.build(priorRows: [:])

        #expect(items.map(\.name) == ["app", "archive", "staging"])
        #expect(items.first?.isExpanded == true)
    }
}

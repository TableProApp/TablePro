//
//  ExportTreeBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// The export tree's rules used to live inside `ExportDialog`, where the only way to reach them was
/// to open a real connection and click Export. These pin the ones that shipped as bugs: a schema
/// section that stayed shut over a correctly ticked row, a container listed with no objects in it,
/// and a row losing its checkboxes across the reload a format change causes.
@Suite("Export tree building")
@MainActor
struct ExportTreeBuilderTests {
    private final class FakeReader: ExportMetadataReading {
        var schemas: [String] = []
        var databases: [String] = []
        var tablesBySchema: [String: [TableInfo]] = [:]
        var flatTables: [TableInfo] = []
        var groupedTables: [String: [TableInfo]] = [:]
        var databasesFailing: Set<String> = []
        var failsDatabaseList = false
        /// Every schema argument the builder asked about, in order, with nil for the connection's own.
        private(set) var requestedSchemas: [String?] = []
        private(set) var loadedContainers: [String] = []

        init(
            schemas: [String] = [],
            databases: [String] = [],
            tablesBySchema: [String: [TableInfo]] = [:],
            flatTables: [TableInfo] = [],
            groupedTables: [String: [TableInfo]] = [:],
            databasesFailing: Set<String> = [],
            failsDatabaseList: Bool = false
        ) {
            self.schemas = schemas
            self.databases = databases
            self.tablesBySchema = tablesBySchema
            self.flatTables = flatTables
            self.groupedTables = groupedTables
            self.databasesFailing = databasesFailing
            self.failsDatabaseList = failsDatabaseList
        }

        struct ReadFailure: Error {}

        func fetchSchemas() async throws -> [String] { schemas }

        func fetchDatabases() async throws -> [String] {
            if failsDatabaseList { throw ReadFailure() }
            return databases
        }

        func fetchTables(schema: String?) async throws -> [TableInfo] {
            requestedSchemas.append(schema)
            guard let schema else { return flatTables }
            if databasesFailing.contains(schema) { throw ReadFailure() }
            return tablesBySchema[schema] ?? []
        }

        func fetchTablesGroupedByDatabase() async -> [String: [TableInfo]] { groupedTables }

        func loadObjects(request: ExportObjectLoader.Request, tables: [TableInfo]) async -> [ExportObjectItem] {
            loadedContainers.append(request.containerName)
            return tables.map {
                ExportObjectItem(
                    name: $0.name,
                    databaseName: request.containerName,
                    kind: PluginExportObjectKind.from(tableType: $0.type.rawValue)
                )
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

    /// The catalog read is one query for every database, and no engine has to answer it: it throws on
    /// Kafka and Cassandra, and a MySQL proxy answers it from its own backend rather than from the
    /// databases it publishes, so a database it did not describe is read from the driver instead.
    @Test("A database the catalog read did not describe is read from the driver")
    func undescribedDatabaseIsReadFromTheDriver() async throws {
        let reader = FakeReader(
            databases: ["app", "archive"],
            tablesBySchema: ["archive": [Self.makeTable("old")]],
            groupedTables: ["app": [Self.makeTable("users")]]
        )
        let builder = Self.builder(
            typeId: Self.databaseTypeId,
            preselection: .tables(names: [], scope: nil),
            reader: reader
        )

        let items = try await builder.build(priorRows: [:])

        #expect(reader.requestedSchemas == ["archive"])
        #expect(items.first { $0.name == "archive" }?.objects.map(\.name) == ["old"])
        #expect(items.first { $0.name == "app" }?.objects.map(\.name) == ["users"])
    }

    /// A MySQL account that lists a database it cannot open gets the server's refusal for that one
    /// database. The rest of the tree is still what the user came to export.
    @Test("A database the account cannot read is left out instead of failing the dialog")
    func unreadableDatabaseIsLeftOut() async throws {
        let reader = FakeReader(
            databases: ["app", "mysql", "staging"],
            tablesBySchema: ["staging": [Self.makeTable("draft")]],
            flatTables: [Self.makeTable("users")],
            databasesFailing: ["mysql"]
        )
        let builder = Self.builder(
            typeId: Self.databaseTypeId,
            preselection: .tables(names: [], scope: nil),
            reader: reader
        )

        let items = try await builder.build(priorRows: [:])

        #expect(items.map(\.name) == ["app", "staging"])
        #expect(reader.loadedContainers.contains("mysql"))
    }

    /// The connection's own database is read the way every other read of it is, through the driver's
    /// current one, so a driver that answers only about the database it is on still answers.
    @Test("The connection's own database is read without naming it")
    func currentDatabaseIsReadWithoutASchema() async throws {
        let reader = FakeReader(
            databases: ["app"],
            flatTables: [Self.makeTable("users")]
        )
        let builder = Self.builder(
            typeId: Self.databaseTypeId,
            preselection: .tables(names: [], scope: nil),
            reader: reader
        )

        _ = try await builder.build(priorRows: [:])

        #expect(reader.requestedSchemas == [nil])
    }

    /// The builder decides no kind of its own: whatever the listing said an object is, is what the
    /// tree row carries. What the catalog read's own type strings map to is pinned separately by
    /// `ExportCatalogTableTypeTests`.
    @Test("The builder carries an object's kind through unchanged")
    func kindsSurviveTheTreeBuild() async throws {
        let reader = FakeReader(
            databases: ["app"],
            flatTables: [
                TableInfo(name: "orders", type: .partitionedTable, rowCount: nil),
                TableInfo(name: "recent", type: .view, rowCount: nil),
            ]
        )
        let builder = Self.builder(
            typeId: Self.databaseTypeId,
            preselection: .tables(names: [], scope: nil),
            reader: reader
        )

        let items = try await builder.build(priorRows: [:])
        let objects = try #require(items.first?.objects)

        #expect(objects.first { $0.name == "orders" }?.kind == .table)
        #expect(objects.first { $0.name == "recent" }?.kind == .view)
    }

    @Test("A failed database list still fails the dialog")
    func failedDatabaseListFails() async {
        let reader = FakeReader(failsDatabaseList: true)
        let builder = Self.builder(
            typeId: Self.databaseTypeId,
            preselection: .tables(names: [], scope: nil),
            reader: reader
        )

        await #expect(throws: (any Error).self) {
            _ = try await builder.build(priorRows: [:])
        }
    }
}

/// What the export dialog's own `information_schema.TABLES` read makes of each `TABLE_TYPE` it can
/// be answered with. The read builds a driver of its own, so no test reaches it through
/// `ExportMetadataReading`; the mapping is pinned here and the reader has nothing else to decide.
@Suite("Export catalog table types")
struct ExportCatalogTableTypeTests {
    /// Measured on MySQL 8.4.11 and MariaDB 11.4.13: every one of `information_schema`'s 78 and 82
    /// objects is `SYSTEM VIEW`. Read as a system table, `PluginExportObjectKind.from` answers
    /// `.table`, which turns Structure, Drop and Data on and dumps `information_schema.COLUMNS` row
    /// by row.
    @Test("A system view exports as a view")
    func systemViewIsAView() {
        let decoded = ExportCatalogTableType.decode("SYSTEM VIEW")
        #expect(decoded == .view)
        #expect(PluginExportObjectKind.from(tableType: decoded.rawValue) == .view)
    }

    /// A system table that is not a view holds rows of its own, so it stays a table.
    @Test("A system table stays a table")
    func systemTableStaysATable() {
        let decoded = ExportCatalogTableType.decode("SYSTEM TABLE")
        #expect(decoded == .systemTable)
        #expect(PluginExportObjectKind.from(tableType: decoded.rawValue) == .table)
    }

    @Test("The ordinary spellings keep the driver's own mapping")
    func knownSpellingsMapThroughTheDriverVocabulary() {
        let cases: [(declared: String, expected: TableInfo.TableType)] = [
            ("BASE TABLE", .table),
            ("VIEW", .view),
            ("MATERIALIZED VIEW", .materializedView),
            ("FOREIGN TABLE", .foreignTable),
            ("PARTITIONED TABLE", .partitionedTable),
            ("SEQUENCE", .sequence),
        ]
        for testCase in cases {
            #expect(ExportCatalogTableType.decode(testCase.declared) == testCase.expected, "\(testCase.declared)")
        }
    }

    /// A spelling this app has never seen is exported as a table rather than dropped from the tree,
    /// so an engine that grows a type is still exportable.
    @Test("An unknown spelling falls back to a table")
    func unknownSpellingIsATable() {
        #expect(ExportCatalogTableType.decode("QUANTUM TABLE") == .table)
        #expect(ExportCatalogTableType.decode("") == .table)
    }
}

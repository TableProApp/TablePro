//
//  CompareMetadataReadPlanTests.swift
//  TableProTests
//
//  What a comparison costs a server, counted.
//
//  The read used to be four statements per table per side, so a 200-table pair
//  was 1,600 round trips before one difference appeared on screen. These pin the
//  count rather than the wall clock: a driver that answers a whole schema in one
//  query is asked once no matter how many tables it holds, and a driver that
//  cannot is still asked correctly.
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class CompareMetadataReadPlanTests: XCTestCase {
    private func tables(_ count: Int) -> [PluginTableInfo] {
        (0 ..< count).map { PluginTableInfo(name: "t\($0)", schema: "public", comment: nil) }
    }

    // MARK: - A driver with the whole-schema reads

    func testAWholeSchemaDriverIsAskedOncePerKindNoMatterHowManyTables() async throws {
        let driver = CountingMetadataDriver(bulk: true)

        let reads = try await CompareMetadataService.read(
            tables: tables(200), schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(reads.count, 200)
        XCTAssertEqual(driver.count(of: "fetchAllColumns"), 1)
        XCTAssertEqual(driver.count(of: "fetchAllIndexes"), 1)
        XCTAssertEqual(driver.count(of: "fetchAllForeignKeys"), 1)
        XCTAssertEqual(driver.count(of: "fetchAllTableMetadata"), 1)
        XCTAssertEqual(driver.totalCalls, 4, "a 200-table schema costs four statements, not eight hundred")
    }

    func testNoPerTableReadSurvivesTheWholeSchemaPath() async throws {
        let driver = CountingMetadataDriver(bulk: true)

        _ = try await CompareMetadataService.read(
            tables: tables(50), schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(driver.count(of: "fetchColumns"), 0)
        XCTAssertEqual(driver.count(of: "fetchIndexes"), 0)
        XCTAssertEqual(driver.count(of: "fetchForeignKeys"), 0)
        XCTAssertEqual(driver.count(of: "fetchTableMetadata"), 0)
    }

    func testTheWholeSchemaValuesReachTheRead() async throws {
        let driver = CountingMetadataDriver(bulk: true)

        let reads = try await CompareMetadataService.read(
            tables: tables(3), schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        let snapshot = try XCTUnwrap(reads.first?.snapshot)
        XCTAssertEqual(snapshot.columns.map(\.name), ["id"])
        XCTAssertEqual(snapshot.indexes.map(\.name), ["t0_pkey"])
        XCTAssertEqual(snapshot.engine, "TestEngine")
    }

    // MARK: - A driver without them

    func testADriverWithoutWholeSchemaReadsStillReadsEveryTable() async throws {
        let driver = CountingMetadataDriver(bulk: false)

        let reads = try await CompareMetadataService.read(
            tables: tables(6), schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(reads.count, 6)
        XCTAssertEqual(driver.count(of: "fetchColumns"), 6)
        XCTAssertEqual(driver.count(of: "fetchIndexes"), 6)
        XCTAssertEqual(driver.count(of: "fetchForeignKeys"), 6)
        XCTAssertEqual(driver.count(of: "fetchTableMetadata"), 6)
        XCTAssertEqual(driver.count(of: "fetchAllColumns"), 0, "a driver that has not declared one is never asked")
    }

    /// A caller that named the tables it wants would have the whole-schema queries read the rest of
    /// the database to throw it away, so those callers keep the per-table reads.
    func testANarrowedReadStaysPerTableEvenOnAWholeSchemaDriver() async throws {
        let driver = CountingMetadataDriver(bulk: true)

        _ = try await CompareMetadataService.read(
            tables: tables(2), schema: "public", profile: .structure,
            narrowed: true, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(driver.count(of: "fetchAllColumns"), 0)
        XCTAssertEqual(driver.count(of: "fetchColumns"), 2)
    }

    // MARK: - Profiles

    func testADataComparisonNeverReadsIndexesOrTableMetadata() async throws {
        let driver = CountingMetadataDriver(bulk: true)

        _ = try await CompareMetadataService.read(
            tables: tables(10), schema: "public", profile: .data,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(driver.count(of: "fetchAllColumns"), 1)
        XCTAssertEqual(driver.count(of: "fetchAllForeignKeys"), 1, "the statement ordering needs them")
        XCTAssertEqual(driver.count(of: "fetchAllIndexes"), 0)
        XCTAssertEqual(driver.count(of: "fetchAllTableMetadata"), 0)
    }

    func testADataComparisonOnAPerTableDriverSkipsThemToo() async throws {
        let driver = CountingMetadataDriver(bulk: false)

        _ = try await CompareMetadataService.read(
            tables: tables(4), schema: "public", profile: .data,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(driver.count(of: "fetchColumns"), 4)
        XCTAssertEqual(driver.count(of: "fetchIndexes"), 0)
        XCTAssertEqual(driver.count(of: "fetchTableMetadata"), 0)
    }

    // MARK: - Failure

    /// A whole-schema query that fails takes nothing with it. The per-table read reports against
    /// the one table it belongs to, which is what keeps one unreadable table from losing the
    /// comparison.
    func testAFailedWholeSchemaReadFallsBackToThePerTableRead() async throws {
        let driver = CountingMetadataDriver(bulk: true)
        driver.failsBulkColumns = true

        let reads = try await CompareMetadataService.read(
            tables: tables(3), schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(driver.count(of: "fetchColumns"), 3)
        XCTAssertEqual(reads.compactMap(\.snapshot).count, 3)
    }

    /// An index read that failed is not an answer of "no indexes". Reading it as one made the sync
    /// script offer `DROP INDEX` for every index the table really has, which is what a MySQL proxy
    /// whose per-table statement is refused produces.
    func testAThrownPerTableIndexReadFailsItsTable() async throws {
        let driver = CountingMetadataDriver(bulk: false)
        driver.failingIndexTable = "t1"

        let reads = try await CompareMetadataService.read(
            tables: tables(3), schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(reads.filter { $0.failure != nil }.map(\.table.name), ["t1"])
        XCTAssertEqual(reads.compactMap(\.snapshot).count, 2)
    }

    func testAThrownPerTableForeignKeyReadFailsItsTable() async throws {
        let driver = CountingMetadataDriver(bulk: false)
        driver.failingForeignKeyTable = "t2"

        let reads = try await CompareMetadataService.read(
            tables: tables(3), schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(reads.filter { $0.failure != nil }.map(\.table.name), ["t2"])
    }

    /// A view has neither indexes nor foreign keys, and engines disagree on whether asking answers
    /// empty or refuses, so a refusal there says nothing about the object.
    func testAViewWhoseIndexReadRefusesIsStillCompared() async throws {
        let driver = CountingMetadataDriver(bulk: false)
        driver.failingIndexTable = "v0"

        let reads = try await CompareMetadataService.read(
            tables: [PluginTableInfo(name: "v0", type: "VIEW", schema: "public", comment: nil)],
            schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertNil(reads.first?.failure)
        XCTAssertEqual(reads.first?.indexes.count, 0)
    }

    func testAnUnreadableTableIsReportedWithoutLosingTheOthers() async throws {
        let driver = CountingMetadataDriver(bulk: false)
        driver.failingTable = "t1"

        let reads = try await CompareMetadataService.read(
            tables: tables(3), schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(reads.count, 3)
        XCTAssertEqual(reads.filter { $0.failure != nil }.map(\.table.name), ["t1"])
        XCTAssertEqual(reads.compactMap(\.snapshot).count, 2)
    }

    /// A table listed under one folding and stored under another still has to find its entry.
    func testALookupFoldsCase() async throws {
        let driver = CountingMetadataDriver(bulk: true)
        driver.uppercasesBulkKeys = true

        let reads = try await CompareMetadataService.read(
            tables: tables(2), schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(driver.count(of: "fetchColumns"), 0, "the folded name matched, so nothing was re-read")
        XCTAssertEqual(reads.compactMap(\.snapshot).count, 2)
    }

    // MARK: - Materialized view indexes

    private let materializedView = PluginTableInfo(
        name: "mv", type: "MATERIALIZED VIEW", schema: "public", comment: nil
    )
    private let view = PluginTableInfo(name: "v0", type: "VIEW", schema: "public", comment: nil)
    private let uniqueIndex = PluginIndexInfo(name: "mv_id_idx", columns: ["id"], isUnique: true)

    private func indexNames(_ read: TableStructureRead?) -> [String]? {
        guard case .read(let indexes)? = read?.objectIndexes else { return nil }
        return indexes.map(\.name)
    }

    func testACarriedMaterializedViewReadsItsIndexes() async throws {
        let driver = CountingMetadataDriver(bulk: false)
        driver.objectIndexes = ["mv": [uniqueIndex]]

        let reads = try await CompareMetadataService.read(
            tables: [materializedView], schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [.materializedView], using: driver
        )

        XCTAssertEqual(indexNames(reads.first), ["mv_id_idx"])
        XCTAssertEqual(driver.count(of: "fetchIndexes"), 1)
    }

    /// A failed read is not an answer of "no indexes": a script written from one would drop the
    /// view and create it again without the unique index its concurrent refresh needs.
    func testACarriedMaterializedViewWhoseIndexReadFailsKeepsTheFailure() async throws {
        let driver = CountingMetadataDriver(bulk: false)
        driver.failingIndexTable = "mv"

        let reads = try await CompareMetadataService.read(
            tables: [materializedView], schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [.materializedView], using: driver
        )

        let read = try XCTUnwrap(reads.first)
        guard case .failed(let reason)? = read.objectIndexes else {
            return XCTFail("a refused index read must be reported, got \(String(describing: read.objectIndexes))")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(read.failure, "the failure belongs to the indexes, so the definition is still read")
    }

    func testAViewIsNotAskedForIndexesWhereItsKindTakesNone() async throws {
        let driver = CountingMetadataDriver(bulk: false)
        driver.failingIndexTable = "v0"

        let reads = try await CompareMetadataService.read(
            tables: [view, materializedView], schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [.materializedView], using: driver
        )

        XCTAssertEqual(driver.count(of: "fetchIndexes"), 1, "only the materialized view is asked")
        XCTAssertNil(reads.first { $0.table.name == "v0" }?.objectIndexes)
        XCTAssertNil(reads.first { $0.table.name == "v0" }?.failure)
    }

    /// Redshift and Snowflake answer with sort, distribution or clustering keys, which no
    /// `CREATE INDEX` can write back, so an engine whose matrix takes no index on the kind is not
    /// asked at all.
    func testAnEngineWhoseMaterializedViewsTakeNoIndexIsNeverAsked() async throws {
        let driver = CountingMetadataDriver(bulk: false)
        driver.objectIndexes = ["mv": [uniqueIndex]]

        let reads = try await CompareMetadataService.read(
            tables: [materializedView], schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: driver
        )

        XCTAssertEqual(driver.count(of: "fetchIndexes"), 0)
        XCTAssertNil(reads.first?.objectIndexes)
        XCTAssertEqual(reads.first?.indexes.count, 0)
    }

    func testTheWholeSchemaIndexReadReachesACarriedMaterializedView() async throws {
        let driver = CountingMetadataDriver(bulk: true)
        driver.objectIndexes = ["mv": [uniqueIndex]]

        let reads = try await CompareMetadataService.read(
            tables: [materializedView], schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [.materializedView], using: driver
        )

        XCTAssertEqual(indexNames(reads.first), ["mv_id_idx"])
        XCTAssertEqual(driver.count(of: "fetchIndexes"), 0)
        XCTAssertEqual(driver.count(of: "fetchAllIndexes"), 1)
    }

    func testADataComparisonReadsNoMaterializedViewIndexes() async throws {
        let driver = CountingMetadataDriver(bulk: false)
        driver.objectIndexes = ["mv": [uniqueIndex]]

        let reads = try await CompareMetadataService.read(
            tables: [materializedView], schema: "public", profile: .data,
            narrowed: false, databaseType: .postgresql, indexedKinds: [.materializedView], using: driver
        )

        XCTAssertEqual(driver.count(of: "fetchIndexes"), 0)
        XCTAssertNil(reads.first?.objectIndexes)
    }
}

private final class CountingMetadataDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    private let bulk: Bool

    var failsBulkColumns = false
    var failingTable: String?
    var failingIndexTable: String?
    var failingForeignKeyTable: String?
    var uppercasesBulkKeys = false
    var objectIndexes: [String: [PluginIndexInfo]] = [:]

    init(bulk: Bool) {
        self.bulk = bulk
    }

    func count(of call: String) -> Int {
        lock.withLock { calls[call] ?? 0 }
    }

    var totalCalls: Int {
        lock.withLock { calls.values.reduce(0, +) }
    }

    private func record(_ call: String) {
        lock.withLock { calls[call, default: 0] += 1 }
    }

    private func key(_ table: String) -> String {
        uppercasesBulkKeys ? table.uppercased() : table
    }

    private func columns(for table: String) -> [PluginColumnInfo] {
        [PluginColumnInfo(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true)]
    }

    private func indexes(for table: String) -> [PluginIndexInfo] {
        [PluginIndexInfo(name: "\(table)_pkey", columns: ["id"], isUnique: true, isPrimary: true)]
    }

    private var knownTables: [String] { (0 ..< 200).map { "t\($0)" } }

    // MARK: - Whole schema

    var providesBulkColumnFetch: Bool { bulk }
    var providesBulkIndexFetch: Bool { bulk }
    var providesBulkForeignKeyFetch: Bool { bulk }
    var providesBulkTableMetadataFetch: Bool { bulk }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        record("fetchAllColumns")
        if failsBulkColumns { throw CocoaError(.fileReadUnknown) }
        return Dictionary(uniqueKeysWithValues: knownTables.map { (key($0), columns(for: $0)) })
    }

    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        record("fetchAllIndexes")
        return Dictionary(uniqueKeysWithValues: knownTables.map { (key($0), indexes(for: $0)) })
            .merging(objectIndexes) { table, _ in table }
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        record("fetchAllForeignKeys")
        return [:]
    }

    func fetchAllTableMetadata(schema: String?) async throws -> [String: PluginTableMetadata] {
        record("fetchAllTableMetadata")
        return Dictionary(
            uniqueKeysWithValues: knownTables.map {
                (key($0), PluginTableMetadata(tableName: $0, engine: "TestEngine"))
            }
        )
    }

    // MARK: - Per table

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        record("fetchColumns")
        if table == failingTable { throw CocoaError(.fileReadNoSuchFile) }
        return columns(for: table)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        record("fetchIndexes")
        if table == failingIndexTable { throw CocoaError(.fileReadNoPermission) }
        return objectIndexes[table] ?? indexes(for: table)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        record("fetchForeignKeys")
        if table == failingForeignKeyTable { throw CocoaError(.fileReadNoPermission) }
        return []
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        record("fetchTableMetadata")
        return PluginTableMetadata(tableName: table, engine: "TestEngine")
    }

    // MARK: - Unused

    func connect() async throws {}
    func disconnect() {}
    var isConnected: Bool { true }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchDatabases() async throws -> [String] { [] }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        record("fetchTables")
        return knownTables.map { PluginTableInfo(name: $0, schema: schema, comment: nil) }
    }
}

//
//  RowImportBatchTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// Each file of a folder starts on the table its name matches, or a new table named the way the one-file sheet
/// names it, and the run starts only when every file is ready and the files agree on one transaction.
@MainActor
struct RowImportBatchTests {
    private let suite: EphemeralDefaults
    private let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)

    init() throws {
        suite = try EphemeralDefaults()
    }

    private var scope: DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: "shop", schema: "public")
    }

    private final class Catalog {
        var tables: [String] = []
        var columns: [String: [String]] = [:]
        var fields: [String: [String]] = [:]
        var configurations: [String: RowImportRunner.Configuration] = [:]
        var unreadable: Set<String> = []
        var tableListFails = false
    }

    private struct Unreadable: LocalizedError {
        var errorDescription: String? { "Line 3 is not valid UTF-8 text." }
    }

    private static func configuration(
        _ errorHandling: ImportErrorHandling = .stopAndRollback,
        wrap: Bool = true,
        deleteExisting: Bool = false
    ) -> RowImportRunner.Configuration {
        RowImportRunner.Configuration(errorHandling: errorHandling, wrapInTransaction: wrap, deleteExistingRows: deleteExisting)
    }

    private func services(_ catalog: Catalog) -> RowImportBatch.Services {
        RowImportBatch.Services(
            fetchTables: { _ in
                if catalog.tableListFails { throw DatabaseError.notConnected }
                return catalog.tables.map { TableInfo(name: $0, type: .table, rowCount: nil, schema: "public") }
            },
            fetchColumns: { table, _ in catalog.columns[table] ?? [] },
            detectFields: { _, url, _ in
                if catalog.unreadable.contains(url.lastPathComponent) { throw Unreadable() }
                return (catalog.fields[url.lastPathComponent] ?? ["id", "name"]).map {
                    PluginImportField(name: $0, sampleValue: nil, inferredType: .text)
                }
            },
            configuration: { catalog.configurations[$0] ?? Self.configuration() },
            formatName: { $0.uppercased() },
            sqlType: { _ in "TEXT" }
        )
    }

    private func makeBatch(_ names: [String], catalog: Catalog) async -> RowImportBatch {
        let files = names.map { name in
            ImportBatchFiles.File(
                url: URL(fileURLWithPath: "/tmp/exports/\(name)"),
                formatId: URL(fileURLWithPath: name).pathExtension
            )
        }
        let batch = RowImportBatch(
            files: files,
            leftOut: [],
            connection: connection,
            scope: scope,
            services: services(catalog),
            mappingStore: ImportColumnMappingStore(defaults: suite.defaults)
        )
        await batch.loadTables()
        await batch.readFiles()
        return batch
    }

    private func targets(_ batch: RowImportBatch) -> [String] {
        batch.files.map { file in
            switch file.target.destination {
            case .existingTable: return "existing:\(file.target.existingTable ?? "")"
            case .newTable: return "new:\(file.target.newTableName)"
            }
        }
    }

    @Test("A file whose name matches a table goes into it, the rest into new tables named after them")
    func proposesMatchingAndNewTables() async {
        let catalog = Catalog()
        catalog.tables = ["orders"]
        catalog.columns["orders"] = ["id", "name"]

        let batch = await makeBatch(["Orders.csv", "Customer List.csv"], catalog: catalog)

        #expect(targets(batch) == ["existing:orders", "new:customer_list"])
        #expect(batch.files.allSatisfy { $0.read == .ready })
        #expect(batch.canImport)
    }

    @Test("Two files that would get one new name get two, and neither takes a name the database has")
    func newNamesAreUniqueAcrossTheRun() async {
        let catalog = Catalog()
        catalog.tables = ["sales_2024_view"]

        let batch = await makeBatch(["sales 2024.csv", "sales-2024.json", "sales_2024.csv"], catalog: catalog)

        #expect(targets(batch) == ["new:sales_2024", "new:sales_2024_2", "new:sales_2024_3"])
        #expect(batch.problem == nil)
    }

    @Test("Twenty files of a folder are ready to import into twenty new tables")
    func twentyFilesAreReady() async throws {
        let names = (1...20).map { "export_\($0).csv" }
        let batch = await makeBatch(names, catalog: Catalog())

        let plan = try #require(batch.plan())
        #expect(plan.items.count == 20)
        #expect(plan.newTables.count == 20)
        #expect(Set(plan.items.map(\.targetTable)).count == 20)
    }

    @Test("Two files given one new table name stop the run")
    func duplicateNewTableNameIsAProblem() async {
        let batch = await makeBatch(["a.csv", "b.csv"], catalog: Catalog())
        let second = batch.files[1].id
        var target = batch.files[1].target
        target.newTableName = "a"
        batch.apply(target, to: second)

        #expect(batch.problem == String(format: String(localized: "Two files create a table named %@."), "a"))
        #expect(batch.plan() == nil)
    }

    @Test("Formats that handle errors differently cannot share one transaction")
    func formatsMustAgreeOnThePolicy() async {
        let catalog = Catalog()
        catalog.configurations["json"] = Self.configuration(.skipAndContinue)

        let batch = await makeBatch(["a.csv", "b.json"], catalog: catalog)

        #expect(batch.problem == String(
            format: String(localized: "Set On error and Wrap in transaction the same for %@."),
            ["CSV", "JSON"].formatted(.list(type: .and))
        ))
        #expect(!batch.canImport)
    }

    @Test("Wrap in transaction does not split formats that all skip and continue")
    func skipAndContinueIgnoresWrap() async {
        let catalog = Catalog()
        catalog.configurations["csv"] = Self.configuration(.skipAndContinue, wrap: true)
        catalog.configurations["json"] = Self.configuration(.skipAndContinue, wrap: false)

        let batch = await makeBatch(["a.csv", "b.json"], catalog: catalog)

        #expect(batch.problem == nil)
        #expect(batch.policy?.usesTransaction == false)
    }

    @Test("Delete existing rows refuses a table two files fill")
    func clearingATableTwiceIsAProblem() async {
        let catalog = Catalog()
        catalog.tables = ["orders"]
        catalog.columns["orders"] = ["id", "name"]
        catalog.configurations["csv"] = Self.configuration(deleteExisting: true)

        let batch = await makeBatch(["orders.csv", "march.csv"], catalog: catalog)
        batch.choose(.existingTable("orders"), for: batch.files[1].id)
        await batch.readFiles()

        #expect(batch.problem?.hasPrefix("orders takes rows from two files") == true)
    }

    @Test("Delete existing rows refuses a table one file creates and another fills")
    func clearingANewTableTwiceIsAProblem() async {
        let catalog = Catalog()
        catalog.configurations["csv"] = Self.configuration(deleteExisting: true)
        let batch = await makeBatch(["orders.csv", "march.csv"], catalog: catalog)
        batch.planner.recordCreated(TableScope(table: "orders", in: scope), createTableSQL: "CREATE TABLE orders (id TEXT)")
        catalog.tables = ["orders"]
        catalog.columns["orders"] = ["id", "name"]
        await batch.loadTables()
        batch.choose(.existingTable("orders"), for: batch.files[1].id)
        await batch.readFiles()

        #expect(batch.problem?.hasPrefix("orders takes rows from two files") == true)
    }

    @Test("A file that cannot be read names itself, and leaving it out lets the rest import")
    func unreadableFileCanBeLeftOut() async {
        let catalog = Catalog()
        catalog.unreadable = ["broken.csv"]

        let batch = await makeBatch(["good.csv", "broken.csv"], catalog: catalog)

        #expect(batch.problem == String(
            format: String(localized: "%1$@ cannot be read. %2$@"), "broken.csv", "Line 3 is not valid UTF-8 text."
        ))
        batch.setIncluded(false, for: batch.files[1].id)
        #expect(batch.canImport)
        #expect(batch.plan()?.items.map(\.sourceName) == ["good.csv"])
    }

    @Test("A file into an existing table maps its fields by name and imports only mapped ones")
    func existingTableMapsByName() async throws {
        let catalog = Catalog()
        catalog.tables = ["people"]
        catalog.columns["people"] = ["id", "full_name"]
        catalog.fields["people.csv"] = ["id", "full_name", "notes"]

        let batch = await makeBatch(["people.csv"], catalog: catalog)

        let plan = try #require(batch.plan())
        #expect(plan.items.first?.columnMapping == ["id": "id", "full_name": "full_name"])
        #expect(plan.newTables.isEmpty)
    }

    @Test("Without a table list every file still gets a new table, and the list error is shown")
    func failedTableListStillProposes() async {
        let catalog = Catalog()
        catalog.tableListFails = true

        let batch = await makeBatch(["orders.csv"], catalog: catalog)

        #expect(targets(batch) == ["new:orders"])
        #expect(batch.tableListError != nil)
        #expect(batch.catalogNameKeys == nil)
    }

    @Test("A table the run created on a failed attempt is not reported as taken on the retry")
    func ownTablesAreNotTaken() async {
        let catalog = Catalog()
        let batch = await makeBatch(["orders.csv"], catalog: catalog)
        batch.planner.recordCreated(TableScope(table: "orders", in: scope), createTableSQL: "CREATE TABLE orders (id TEXT)")
        catalog.tables = ["orders"]
        await batch.loadTables()

        #expect(targets(batch) == ["new:orders"])
        #expect(batch.problem == nil)
    }
}

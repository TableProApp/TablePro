import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
struct ForeignKeyPreviewModelTests {
    private static let tenantUser = ForeignKeyReference(table: "tenant_users", schema: "crm", parts: [
        ForeignKeyReference.Part(column: "tenant_id", value: "2"),
        ForeignKeyReference.Part(column: "id", value: "5")
    ])

    private static let userColumns = [
        ColumnInfo(name: "tenant_id", typeName: "INT", ordinalPosition: 0),
        ColumnInfo(name: "id", typeName: "INT", ordinalPosition: 1),
        ColumnInfo(name: "region_id", typeName: "INT", ordinalPosition: 2),
        ColumnInfo(name: "avatar_id", typeName: "VARBINARY(16)", ordinalPosition: 3),
        ColumnInfo(name: "manager_id", typeName: "INT", ordinalPosition: 4)
    ]

    private static let userKeys = [
        ForeignKeyInfo(name: "users_region_fk", column: "region_id", referencedTable: "regions", referencedColumn: "id"),
        ForeignKeyInfo(name: "users_avatar_fk", column: "avatar_id", referencedTable: "avatars", referencedColumn: "id"),
        ForeignKeyInfo(name: "users_manager_fk", column: "manager_id", referencedTable: "tenant_users", referencedColumn: "id")
    ]

    private static func session(_ driver: MockDatabaseDriver) -> ConnectionSession {
        ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "test")
    }

    private static func driver(rows: [[String?]]) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: userColumns, rows: rows, rowsAffected: 0, executionTime: 0))
        ]
        driver.scriptedForeignKeys = userKeys
        return driver
    }

    private static func model(_ driver: MockDatabaseDriver?, reference: ForeignKeyReference? = nil) -> ForeignKeyPreviewModel {
        ForeignKeyPreviewModel(
            reference: reference ?? tenantUser,
            session: driver.map { Self.session($0) },
            databaseType: .postgresql
        )
    }

    private static let userRow: [String?] = ["2", "5", "9", "0A0B", nil]

    @Test("No session is a Not Connected error, not a missing row, and Open Table stays off")
    func noSessionIsAnError() async {
        let model = Self.model(nil)
        await model.load()

        guard case .failed(let error) = model.phase else {
            Issue.record("Expected a failure, got \(model.phase)")
            return
        }
        #expect(error.title == String(localized: "Not Connected"))
        #expect(error.message == String(localized: "No active database session."))
        #expect(!model.canOpen)
    }

    @Test("The lookup matches every pair of the key in the reference's schema")
    func lookupMatchesEveryPair() async throws {
        let driver = Self.driver(rows: [Self.userRow])
        let model = Self.model(driver)
        await model.load()

        let query = try #require(driver.executedQueries.first)
        #expect(query == SQLBuilder.buildSingleRowLookup(
            table: "tenant_users", schema: "crm",
            key: [(column: "tenant_id", value: "2"), (column: "id", value: "5")],
            columns: [], type: .postgresql, driver: driver
        ))
        #expect(query.hasPrefix("SELECT * FROM \"crm\".\"tenant_users\""))
        #expect(query.contains("\"tenant_id\" = '2'"))
        #expect(query.contains("\"id\" = '5'"))
    }

    // MySQL finds no row for `bit_col = '5'`, and the browser's filter compares the same column bare.
    @Test("The lookup reads the referenced table's columns first and takes each literal from their types")
    func lookupTakesLiteralsFromTheColumns() async throws {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = [
            ColumnInfo(name: "flags", typeName: "bit(8)", ordinalPosition: 0),
            ColumnInfo(name: "code", typeName: "varchar(10)", ordinalPosition: 1)
        ]
        let reference = ForeignKeyReference(table: "parents", schema: "crm", parts: [
            ForeignKeyReference.Part(column: "flags", value: "5"),
            ForeignKeyReference.Part(column: "code", value: "02134")
        ])
        let model = ForeignKeyPreviewModel(reference: reference, session: Self.session(driver), databaseType: .mysql)
        await model.load()

        #expect(driver.fetchColumnsSchemas == ["crm"])
        let query = try #require(driver.executedQueries.first)
        #expect(query.contains("WHERE `flags` = 5 AND `code` = '02134' "))
    }

    @Test("A failed column read still looks the row up, with every value quoted")
    func columnReadFailureQuotesTheKey() async throws {
        let driver = Self.driver(rows: [Self.userRow])
        driver.fetchColumnsError = MockDatabaseDriver.MockError.scripted
        let model = Self.model(driver)
        await model.load()

        #expect(model.isLoaded)
        let query = try #require(driver.executedQueries.first)
        #expect(query.contains("\"tenant_id\" = '2' AND \"id\" = '5'"))
    }

    @Test("The referenced table's keys are read in the reference's schema, and chained links resolve against it")
    func chainedLinksUseTheReferenceSchema() async throws {
        let driver = Self.driver(rows: [Self.userRow])
        let model = Self.model(driver)
        await model.load()

        #expect(model.isLoaded)
        #expect(driver.fetchForeignKeysSchemas == ["crm"])
        let region = try #require(model.fields.first(where: { $0.name == "region_id" })?.reference)
        #expect(region.table == "regions")
        #expect(region.schema == "crm")
        #expect(region.parts == [ForeignKeyReference.Part(column: "id", value: "9")])
    }

    @Test("A binary-typed or NULL key value gets no link, and a column outside every key gets none")
    func binaryAndNullValuesGetNoLink() async {
        let driver = Self.driver(rows: [Self.userRow])
        let model = Self.model(driver)
        await model.load()

        let links = Dictionary(uniqueKeysWithValues: model.fields.map { ($0.name, $0.reference != nil) })
        #expect(links == ["tenant_id": false, "id": false, "region_id": true, "avatar_id": false, "manager_id": false])
    }

    @Test("A failed key read still shows the row, without links")
    func keyReadFailureShowsRowWithoutLinks() async {
        let driver = Self.driver(rows: [Self.userRow])
        driver.fetchForeignKeysError = MockDatabaseDriver.MockError.scripted
        let model = Self.model(driver)
        await model.load()

        #expect(model.isLoaded)
        #expect(model.fields.count == Self.userColumns.count)
        #expect(model.fields.allSatisfy { $0.reference == nil })
        #expect(model.canOpen)
    }

    @Test("No row is the not-found state, and Open Table stays off")
    func noRowIsNotFound() async {
        let model = Self.model(Self.driver(rows: []))
        await model.load()

        guard case .notFound = model.phase else {
            Issue.record("Expected not found, got \(model.phase)")
            return
        }
        #expect(!model.canOpen)
    }

    @Test("A failed lookup is an error, and Open Table stays off")
    func failedLookupIsAnError() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [.failure(MockDatabaseDriver.MockError.scripted)]
        let model = Self.model(driver)
        await model.load()

        guard case .failed(let error) = model.phase else {
            Issue.record("Expected a failure, got \(model.phase)")
            return
        }
        #expect(error.title == String(localized: "Could Not Load the Referenced Row"))
        #expect(!model.canOpen)
        #expect(driver.fetchForeignKeysSchemas.isEmpty)
    }

    @Test("A blank key value previews but cannot open, since the browser drops a blank filter")
    func blankValueCannotOpen() async {
        let blank = ForeignKeyReference(table: "tenant_users", schema: nil, parts: [
            ForeignKeyReference.Part(column: "code", value: "")
        ])
        let model = Self.model(Self.driver(rows: [Self.userRow]), reference: blank)
        await model.load()

        #expect(model.isLoaded)
        #expect(!model.canOpen)
    }

    @Test("Loading again after the row arrived runs no second lookup")
    func loadRunsOnce() async {
        let driver = Self.driver(rows: [Self.userRow])
        let model = Self.model(driver)
        await model.load()
        await model.load()

        #expect(driver.executedQueries.count == 1)
        #expect(driver.fetchForeignKeysSchemas.count == 1)
    }

    @Test("The not-found message names every pair of the key")
    func notFoundMessageNamesEveryPair() {
        let english = Locale(identifier: "en_US")
        #expect(
            ForeignKeyPreviewModel.notFoundMessage(for: Self.tenantUser, locale: english)
                == "No row found in tenant_users where tenant_id = '2' and id = '5'."
        )
        let single = ForeignKeyReference(table: "users", schema: nil, parts: [ForeignKeyReference.Part(column: "id", value: "5")])
        #expect(ForeignKeyPreviewModel.notFoundMessage(for: single, locale: english) == "No row found in users where id = '5'.")
    }
}

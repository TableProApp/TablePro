//
//  CompareObjectScopeTests.swift
//  TableProTests
//
//  Two things the comparison used to get wrong before an endpoint was a scope and an object had a
//  kind: it could not address two databases on one server, and `fetchTables` reports views
//  alongside tables so a view reached the table paths and produced CREATE TABLE for a view.
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class CompareSyncEndpointScopeTests: XCTestCase {
    private let connectionId = UUID()

    private func endpoint(database: String, schema: String? = nil) -> CompareSyncEndpoint {
        CompareSyncEndpoint(
            scope: DatabaseScope(connectionId: connectionId, database: database, schema: schema),
            connectionName: "server",
            databaseType: .postgresql,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    /// `canCompare` used to key on the connection id, which made this pair identical and refused
    /// the comparison the issue asks for by name: two versions of a schema on one server.
    func testTwoDatabasesOnOneConnectionAreDistinctEndpoints() {
        XCTAssertNotEqual(endpoint(database: "app_prod").id, endpoint(database: "app_staging").id)
    }

    func testTwoSchemasInOneDatabaseAreDistinctEndpoints() {
        XCTAssertNotEqual(
            endpoint(database: "app", schema: "public").id,
            endpoint(database: "app", schema: "sales").id
        )
    }

    func testTheSameScopeIsTheSameEndpoint() {
        XCTAssertEqual(endpoint(database: "app", schema: "public").id, endpoint(database: "app", schema: "public").id)
    }

    func testQualifiedDescriptionNamesEveryLevelThatIsSet() {
        XCTAssertEqual(endpoint(database: "app", schema: "public").qualifiedDescription, "server / app / public")
        XCTAssertEqual(endpoint(database: "app").qualifiedDescription, "server / app")
        XCTAssertEqual(endpoint(database: "").qualifiedDescription, "server")
    }

    func testChangingDatabaseClearsTheSchema() {
        let moved = endpoint(database: "app", schema: "public").withDatabase("other")

        XCTAssertEqual(moved.database, "other")
        XCTAssertNil(moved.schema)
    }

    func testReadOnlyEndpointIsRefusedAsATarget() {
        let readOnly = CompareSyncEndpoint(
            scope: DatabaseScope(connectionId: connectionId, database: "prod", schema: nil),
            connectionName: "prod",
            databaseType: .postgresql,
            safeModeLevel: .readOnly,
            color: .red
        )

        XCTAssertFalse(readOnly.canBeWrittenTo)
        XCTAssertNotNil(readOnly.ineligibleAsTargetReason)
    }
}

final class CompareTableKindClassifierTests: XCTestCase {
    private func table(_ type: String) -> PluginTableInfo {
        PluginTableInfo(name: "orders", type: type, schema: "public", comment: nil)
    }

    func testViewsAreRecognisedHoweverTheEngineSpellsThem() {
        for spelling in ["VIEW", "view", "SYSTEM VIEW", "BASE VIEW"] {
            XCTAssertEqual(CompareTableKindClassifier.kind(of: table(spelling)), .view, spelling)
        }
    }

    func testMaterializedViewsAreTheirOwnKind() {
        for spelling in ["MATERIALIZED VIEW", "MATERIALIZED_VIEW", "materialized view"] {
            XCTAssertEqual(CompareTableKindClassifier.kind(of: table(spelling)), .materializedView, spelling)
        }
    }

    /// PostgreSQL reports PARTITIONED TABLE for an ordinary, directly queryable table. Matching the
    /// literal string TABLE would have silently dropped it from every comparison, which is why the
    /// rule is subtractive.
    func testPartitionedAndForeignTablesStillCompareAsTables() {
        for spelling in ["TABLE", "BASE TABLE", "PARTITIONED TABLE", "FOREIGN TABLE", "LOCAL TEMPORARY"] {
            XCTAssertEqual(CompareTableKindClassifier.kind(of: table(spelling)), .table, spelling)
        }
    }

    func testAForeignTableIsFlaggedSeparatelyFromItsKind() {
        XCTAssertTrue(CompareTableKindClassifier.isForeign(table("FOREIGN TABLE")))
        XCTAssertFalse(CompareTableKindClassifier.isForeign(table("BASE TABLE")))
    }

    func testOnlyATableCarriesRows() {
        XCTAssertTrue(CompareObjectKind.table.carriesRows)
        for kind in CompareObjectKind.allCases where kind != .table {
            XCTAssertFalse(kind.carriesRows, "\(kind.rawValue) holds no rows a data compare can walk")
        }
    }
}

final class DataComparePlanColumnTests: XCTestCase {
    private func plan(generated: Set<String>, keys: [String] = ["id"]) -> DataComparePlan {
        DataComparePlan(
            table: "orders",
            schema: "public",
            columns: ["id", "total", "line_total"],
            columnDescriptors: [
                KeyColumnDescriptor(name: "id", dataType: "bigint"),
                KeyColumnDescriptor(name: "total", dataType: "numeric"),
                KeyColumnDescriptor(name: "line_total", dataType: "numeric")
            ],
            generatedColumns: generated,
            keyColumns: keys,
            isEnabled: true
        )
    }

    /// MySQL rejects an explicit value for a generated column outright and PostgreSQL rejects it
    /// for a stored one, so it is read and compared but never written.
    func testGeneratedColumnsAreReadButNotWritten() {
        let plan = plan(generated: ["line_total"])

        XCTAssertEqual(plan.readColumns, ["id", "total", "line_total"])
        XCTAssertEqual(plan.writeColumns, ["id", "total"])
    }

    func testGeneratedColumnMatchIsCaseInsensitive() {
        XCTAssertEqual(plan(generated: ["LINE_TOTAL"]).writeColumns, ["id", "total"])
    }

    func testATableWhoseSharedColumnsAreAllGeneratedIsNotComparable() {
        let allGenerated = plan(generated: ["id", "total", "line_total"])

        XCTAssertNotNil(DataComparePlan.unavailableReason(for: allGenerated))
    }

    func testKeyDescriptorsCarryOnlyTheKeyColumns() {
        XCTAssertEqual(plan(generated: []).keyDescriptors.map { $0.name }, ["id"])
    }

    func testATableWithNoKeyIsNotComparable() {
        XCTAssertNotNil(DataComparePlan.unavailableReason(for: plan(generated: [], keys: [])))
    }

    func testAKeyMissingFromTheSharedColumnsIsNotComparable() {
        XCTAssertNotNil(DataComparePlan.unavailableReason(for: plan(generated: [], keys: ["tenant_id"])))
    }
}

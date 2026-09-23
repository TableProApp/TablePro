//
//  SourceObjectIndexCarriageTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

@MainActor
final class SourceObjectIndexCarriageTests: XCTestCase {
    func testTheMatrixDecidesWhichKindsCarryIndexes() {
        XCTAssertTrue(SourceObjectIndexes.areCarried(for: .materializedView, by: .postgreSQL))
        XCTAssertFalse(SourceObjectIndexes.areCarried(for: .view, by: .postgreSQL))
        XCTAssertFalse(SourceObjectIndexes.areCarried(for: .materializedView, by: .tablesOnly))
        XCTAssertFalse(SourceObjectIndexes.areCarried(for: .table, by: .postgreSQL))
        XCTAssertFalse(SourceObjectIndexes.areCarried(for: .function, by: .postgreSQL))
    }

    func testPostgreSQLAndPGliteCarryAMaterializedViewsIndexes() {
        XCTAssertEqual(SourceObjectIndexes.carriedKinds(on: .postgresql), [.materializedView])
        XCTAssertEqual(SourceObjectIndexes.carriedKinds(on: .pglite), [.materializedView])
    }

    func testEnginesNobodyHasCuratedCarryNone() {
        XCTAssertEqual(SourceObjectIndexes.carriedKinds(on: .cockroachdb), [])
        XCTAssertEqual(SourceObjectIndexes.carriedKinds(on: .redshift), [])
        XCTAssertEqual(SourceObjectIndexes.carriedKinds(on: DatabaseType(rawValue: "NotARealEngine")), [])
    }
}

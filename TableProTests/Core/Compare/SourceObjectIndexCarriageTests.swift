//
//  SourceObjectIndexCarriageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
final class SourceObjectIndexCarriageTests {
    @Test
    func theMatrixDecidesWhichKindsCarryIndexes() {
        #expect(SourceObjectIndexes.areCarried(for: .materializedView, by: .postgreSQL))
        #expect(!SourceObjectIndexes.areCarried(for: .view, by: .postgreSQL))
        #expect(!SourceObjectIndexes.areCarried(for: .materializedView, by: .tablesOnly))
        #expect(!SourceObjectIndexes.areCarried(for: .table, by: .postgreSQL))
        #expect(!SourceObjectIndexes.areCarried(for: .function, by: .postgreSQL))
    }

    @Test
    func postgreSQLAndPGliteCarryAMaterializedViewsIndexes() {
        #expect(SourceObjectIndexes.carriedKinds(on: .postgresql) == [.materializedView])
        #expect(SourceObjectIndexes.carriedKinds(on: .pglite) == [.materializedView])
    }

    @Test
    func enginesNobodyHasCuratedCarryNone() {
        #expect(SourceObjectIndexes.carriedKinds(on: .cockroachdb) == [])
        #expect(SourceObjectIndexes.carriedKinds(on: .redshift) == [])
        #expect(SourceObjectIndexes.carriedKinds(on: DatabaseType(rawValue: "NotARealEngine")) == [])
    }
}

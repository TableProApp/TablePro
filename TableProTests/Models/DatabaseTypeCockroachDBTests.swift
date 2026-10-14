//
//  DatabaseTypeCockroachDBTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct DatabaseTypeCockroachDBTests {
    @Test("EXPLAIN variants use plain text, not FORMAT JSON")
    func explainVariantsAreText() {
        let variants = DatabaseType.cockroachdb.explainVariants
        #expect(!variants.isEmpty)
        #expect(variants.allSatisfy { !$0.sqlPrefix.uppercased().contains("JSON") })
    }
}

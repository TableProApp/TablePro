//
//  FakeTableOperationProvider.swift
//  TableProTests
//

import Foundation
@testable import TablePro

/// Minimal test double for `TableOperationStatementProvider`.
/// Returns ANSI-style SQL so tests can drive coordinator save paths without a live driver.
final class FakeTableOperationProvider: TableOperationStatementProvider {
    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String] {
        let qualified = schema.map { "\($0).\(table)" } ?? table
        return ["TRUNCATE TABLE \(qualified)\(cascade ? " CASCADE" : "")"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String {
        let qualified = schema.map { "\($0).\(name)" } ?? name
        return "DROP \(objectType) \(qualified)\(cascade ? " CASCADE" : "")"
    }

    func foreignKeyDisableStatements() -> [String]? { nil }

    func foreignKeyEnableStatements() -> [String]? { nil }
}

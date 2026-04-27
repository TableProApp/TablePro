//
//  TableOperationStatementProvider.swift
//  TablePro
//

import Foundation

/// Source of dialect-specific table operation SQL (TRUNCATE, DROP, FK toggles).
/// Conformance is provided by PluginDriverAdapter for runtime use, and
/// can be substituted by tests to exercise table-operation paths without a
/// live driver session.
protocol TableOperationStatementProvider: AnyObject {
    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]
    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String
    func foreignKeyDisableStatements() -> [String]?
    func foreignKeyEnableStatements() -> [String]?
}

extension PluginDriverAdapter: TableOperationStatementProvider {}

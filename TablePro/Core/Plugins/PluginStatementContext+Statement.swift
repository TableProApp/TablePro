//
//  PluginStatementContext+Statement.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginStatementContext {
    /// Decided per statement rather than taken from the gate, because a table tab, an export or MCP
    /// `browse_table` runs a statement the gate never sees. Only the engines whose read verdict Safe Mode
    /// trusts over the driver are classified, so a SQL driver pays nothing for a flag it ignores.
    static func statement(_ query: String, databaseType: DatabaseType) -> PluginStatementContext {
        var context = PluginStatementContext()
        context.readOnly = QueryClassifier.enginesWithProvenReads.contains(databaseType)
            && QueryClassifier.classifyTier(query, databaseType: databaseType) == .safe
        return context
    }
}

//
//  PluginStatementContext+Statement.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

extension PluginStatementContext {
    // Decided per statement for a run the gate never sees, a table tab or an export. Only the engines whose read
    // verdict Safe Mode trusts over the driver are classified, so a SQL driver pays nothing for a flag it ignores.
    static func statement(_ query: String, databaseType: DatabaseType) -> PluginStatementContext {
        var context = PluginStatementContext()
        context.readOnly = QueryClassifier.enginesWithProvenReads.contains(databaseType)
            && QueryClassifier.classifyTier(query, databaseType: databaseType) == .safe
        return context
    }

    // What the caller's approval covered, still marked a read when the text proves one.
    static func statement(
        _ query: String,
        databaseType: DatabaseType,
        approvedAs caller: PluginStatementContext
    ) -> PluginStatementContext {
        var context = caller
        context.readOnly = caller.readOnly || statement(query, databaseType: databaseType).readOnly
        return context
    }
}

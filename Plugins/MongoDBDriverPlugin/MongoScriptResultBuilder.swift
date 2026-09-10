import Foundation
import TableProPluginKit

/// Turns what a statement evaluated to into the result the grid shows.
///
/// mongosh prints whatever the statement produced, so the rule here is the same one: documents
/// become a grid, anything a script printed becomes a grid of its own when the statement produced
/// no documents, and a bare value becomes one cell.
enum MongoScriptResultBuilder {
    static func result(
        for outcome: MongoScriptStatementResult,
        startTime: Date,
        documents build: ([[String: Any]], String, Bool) -> PluginQueryResult
    ) -> PluginQueryResult {
        if outcome.producedDocuments, outcome.documents.json.isEmpty {
            // Zero columns reads as write-success in the result pane, so a query that matched
            // nothing has to keep its row-producing shape.
            return PluginQueryResult(
                columns: ["_id"], columnTypeNames: ["ObjectId"], rows: [], rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        if outcome.producedDocuments {
            let grid = build(
                outcome.documents.dictionaries,
                outcome.collection ?? "",
                outcome.documents.isTruncated
            ).withRowsAffected(outcome.rowsAffected)
            guard !outcome.printedLines.isEmpty else { return grid }
            return grid.withStatus(printedSummary(outcome.printedLines))
        }

        if !outcome.printedLines.isEmpty {
            return values(outcome.printedLines, column: MongoScriptText.outputColumn, startTime: startTime)
        }

        if let switched = outcome.databaseSwitch {
            return note(MongoScriptText.switchedDatabase(switched), startTime: startTime)
        }

        guard let rows = outcome.scalarRows, !rows.isEmpty else {
            return PluginQueryResult(
                columns: [], columnTypeNames: [], rows: [], rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
        return values(rows, column: MongoScriptText.resultColumn, startTime: startTime)
    }

    /// One row per value, which is what `print` output and an array of plain values both are.
    private static func values(_ rows: [String], column: String, startTime: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: [column],
            columnTypeNames: ["String"],
            rows: rows.map { [.text($0)] },
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private static func note(_ text: String, startTime: Date) -> PluginQueryResult {
        values([text], column: MongoScriptText.outputColumn, startTime: startTime)
    }

    private static func printedSummary(_ lines: [String]) -> String {
        let joined = lines.joined(separator: " · ")
        guard joined.count > 400 else { return joined }
        return String(joined.prefix(400)) + "…"
    }
}

private extension PluginQueryResult {
    func withRowsAffected(_ count: Int) -> PluginQueryResult {
        guard count != rowsAffected else { return self }
        return PluginQueryResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: count,
            executionTime: executionTime,
            isTruncated: isTruncated,
            statusMessage: statusMessage
        )
    }

    func withStatus(_ message: String) -> PluginQueryResult {
        PluginQueryResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: rowsAffected,
            executionTime: executionTime,
            isTruncated: isTruncated,
            statusMessage: message
        )
    }
}

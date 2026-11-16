import Foundation
import os
import TableProPluginKit

// Answers each catalog statement with the rows recorded for its exact text, nothing for any other, and remembers what
// was read. A statement listed in `failing` throws.
final class RecordedCatalogReads: Sendable {
    struct Refused: Error {}

    private let replies: [String: [[PluginCellValue]]]
    private let failing: Set<String>
    private let readStatements = OSAllocatedUnfairLock<[String]>(initialState: [])

    init(_ replies: [String: [[PluginCellValue]]] = [:], failing: Set<String> = []) {
        self.replies = replies
        self.failing = failing
    }

    var statements: [String] {
        readStatements.withLock { $0 }
    }

    func rows(_ statement: String) throws -> [[PluginCellValue]] {
        readStatements.withLock { $0.append(statement) }
        if failing.contains(statement) { throw Refused() }
        return replies[statement] ?? []
    }

    func result(_ statement: String) throws -> PluginQueryResult {
        let rows = try rows(statement)
        return PluginQueryResult(
            columns: [], columnTypeNames: [], rows: rows, rowsAffected: 0, executionTime: 0
        )
    }
}

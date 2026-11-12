//
//  OperationCompletionCopy.swift
//  TablePro
//

import Foundation

// Explicit singular and plural keys: `^[row](inflect: true)` comes back verbatim when the catalog lacks the key.
internal enum OperationCompletionCopy {
    internal static func title(for completion: OperationCompletion) -> String {
        completion.connectionName
    }

    internal static func subtitle(for completion: OperationCompletion) -> String? {
        completion.databaseName
    }

    internal static func body(for completion: OperationCompletion) -> String {
        let duration = OperationDurationFormatter.string(from: completion.elapsed)

        switch completion.outcome {
        case .cancelled:
            return String(format: String(localized: "Stopped after %@"), duration)
        case .failed(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return String(format: String(localized: "Failed after %@"), duration)
            }
            return String(
                format: String(localized: "Failed after %1$@: %2$@"), duration, truncated(trimmed)
            )
        case .succeeded(let summary):
            return String(
                format: String(localized: "%1$@ in %2$@"), measure(summary, kind: completion.kind), duration
            )
        }
    }

    private static func measure(_ summary: OperationSummary, kind: TrackedOperationKind) -> String {
        if let fileURL = summary.fileURL {
            guard kind == .backup else {
                return String(format: String(localized: "Exported to %@"), fileURL.lastPathComponent)
            }
            return String(format: String(localized: "Backed up to %@"), fileURL.lastPathComponent)
        }
        if let statementCount = summary.statementCount {
            let template = statementCount == 1
                ? String(localized: "Ran %@ statement")
                : String(localized: "Ran %@ statements")
            return String(format: template, formatted(statementCount))
        }
        // Rows returned first: several drivers echo the row count as the affected count for a plain read.
        if let rowsReturned = summary.rowsReturned, rowsReturned > 0 {
            return rowsPhrase(rowsReturned)
        }
        if let rowsAffected = summary.rowsAffected, rowsAffected > 0 {
            let template = rowsAffected == 1
                ? String(localized: "Updated %@ row")
                : String(localized: "Updated %@ rows")
            return String(format: template, formatted(rowsAffected))
        }
        if let rowsReturned = summary.rowsReturned {
            return rowsPhrase(rowsReturned)
        }
        return fallbackMeasure(for: kind)
    }

    private static func rowsPhrase(_ count: Int) -> String {
        let template = count == 1 ? String(localized: "%@ row") : String(localized: "%@ rows")
        return String(format: template, formatted(count))
    }

    private static func formatted(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    private static func fallbackMeasure(for kind: TrackedOperationKind) -> String {
        switch kind {
        case .schemaChange: return String(localized: "Changes applied")
        case .rowSave: return String(localized: "Changes saved")
        case .backup: return String(localized: "Backup finished")
        case .restore: return String(localized: "Restore finished")
        case .compareRun: return String(localized: "Comparison finished")
        case .compareApply: return String(localized: "Sync script applied")
        case .dataImport: return String(localized: "Import finished")
        case .dataExport: return String(localized: "Export finished")
        case .objectCopy: return String(localized: "Copy finished")
        case .query, .queryBatch, .fetchAll, .mcpQuery, .scriptQuery: return String(localized: "Finished")
        }
    }

    // The full error stays in the tab; a dump tool's multi-line stderr is flattened before it is cut.
    private static func truncated(_ reason: String) -> String {
        let flattened = reason
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let limit = 120
        let bridged = flattened as NSString
        guard bridged.length > limit else { return flattened }
        return bridged.substring(to: limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}

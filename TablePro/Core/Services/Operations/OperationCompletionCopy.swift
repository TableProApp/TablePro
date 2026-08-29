//
//  OperationCompletionCopy.swift
//  TablePro
//

import Foundation

/// The words a completion notification uses.
///
/// Counts pick between an explicit singular and plural key rather than using automatic grammar
/// agreement. Measured: `String(localized:defaultValue:)` carrying `^[row](inflect: true)` returns
/// the markup verbatim when the catalog has no entry for the key, so the body would have read
/// "3 ^[row](inflect: true) in 1m 00s". Two keys are less elegant and actually work.
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
            return String(format: String(localized: "Exported to %@"), fileURL.lastPathComponent)
        }
        if let statementCount = summary.statementCount {
            let template = statementCount == 1
                ? String(localized: "Ran %@ statement")
                : String(localized: "Ran %@ statements")
            return String(format: template, formatted(statementCount))
        }
        /// Rows returned is checked first, and the order is load bearing. Several drivers echo the
        /// row count back as the affected count for a plain read (MySQL does it in two places), so
        /// testing affected first tells someone their SELECT updated 1,204 rows.
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

    /// Grouped, because a notification is read at a glance and "1,204" is legible where "1204"
    /// has to be counted.
    private static func formatted(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    private static func fallbackMeasure(for kind: TrackedOperationKind) -> String {
        switch kind {
        case .schemaChange: return String(localized: "Changes applied")
        case .rowSave: return String(localized: "Changes saved")
        case .backup: return String(localized: "Backup finished")
        case .dataImport: return String(localized: "Import finished")
        case .dataExport: return String(localized: "Export finished")
        case .objectCopy: return String(localized: "Copy finished")
        case .query, .queryBatch, .fetchAll, .mcpQuery: return String(localized: "Finished")
        }
    }

    /// A notification body is not an error dialog. The HIG is explicit that an alert, not a
    /// notification, carries an error message, so this announces the outcome and leaves the full
    /// text to the inline error the tab already shows.
    private static func truncated(_ reason: String) -> String {
        let limit = 120
        let bridged = reason as NSString
        guard bridged.length > limit else { return reason }
        return bridged.substring(to: limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}

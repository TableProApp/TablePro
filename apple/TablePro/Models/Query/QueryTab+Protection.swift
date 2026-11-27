import Foundation
import TableProSQLGrammar

extension QueryTab {
    var hasQueryText: Bool {
        StatementBlank.hasContent(content.query)
    }

    var hasExecutedQuery: Bool {
        execution.lastExecutedAt != nil
    }

    // Never reused in place. An empty file counts: a table that took its tab over kept the file, and Save wrote its query there.
    var holdsQueryWork: Bool {
        guard tabType == .query else { return false }
        return hasQueryText || hasExecutedQuery || content.sourceFileURL != nil || isNamedByUser
    }

    // Only a query tab's text or name and a table tab's browse context can be rebuilt; utility tabs hold nothing the user wrote.
    var isReopenCandidate: Bool {
        switch tabType {
        case .query:
            return hasQueryText || isNamedByUser
        case .table:
            return !(tableContext.tableName ?? "").isEmpty
        default:
            return false
        }
    }

    /// Drives the native unsaved-changes dot in the window's close button. A file-backed tab is
    /// dirty when it diverges from disk; a scratch query tab is dirty whenever it holds text,
    /// because that text lives nowhere else.
    var showsUnsavedIndicator: Bool {
        if content.sourceFileURL != nil {
            return content.isFileDirty
        }
        return tabType == .query && hasQueryText
    }
}

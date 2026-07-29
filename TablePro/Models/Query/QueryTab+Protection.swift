import Foundation

extension QueryTab {
    var hasQueryText: Bool {
        !content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasExecutedQuery: Bool {
        execution.lastExecutedAt != nil
    }

    /// A query tab the user has invested work in, either by typing into it or by running it.
    /// A tab holding query work must not be silently reused in place.
    var holdsQueryWork: Bool {
        guard tabType == .query else { return false }
        return hasQueryText || hasExecutedQuery
    }

    /// Whether closing this tab loses something worth bringing back. Only the text of a query
    /// tab and the browse context of a table tab can be reconstructed; the utility tab types
    /// carry no user-authored content.
    var isReopenCandidate: Bool {
        switch tabType {
        case .query:
            return hasQueryText
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

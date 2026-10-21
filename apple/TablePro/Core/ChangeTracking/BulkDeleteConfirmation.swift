import Foundation

struct BulkDeleteConfirmation {
    struct Line: Equatable {
        let text: String
        let table: String
        let filterCondition: String?
    }

    static let maximumVisibleLines = 8

    let deletedRowCount: Int
    let tableName: String?
    let preview: CascadeDeletePreview?

    init(deletedRowCount: Int, tableName: String? = nil, preview: CascadeDeletePreview? = nil) {
        self.deletedRowCount = deletedRowCount
        self.tableName = tableName
        self.preview = preview
    }

    func with(_ preview: CascadeDeletePreview?) -> BulkDeleteConfirmation {
        BulkDeleteConfirmation(deletedRowCount: deletedRowCount, tableName: tableName, preview: preview)
    }

    var isRequired: Bool { deletedRowCount > 0 }

    var title: String {
        guard let tableName, !tableName.isEmpty else {
            return deletedRowCount == 1
                ? String(localized: "Delete this row?")
                : String(format: String(localized: "Delete %lld rows?"), deletedRowCount)
        }
        return deletedRowCount == 1
            ? String(format: String(localized: "Delete this row from %@?"), tableName)
            : String(format: String(localized: "Delete %lld rows from %@?"), deletedRowCount, tableName)
    }

    var message: String {
        let permanent = String(localized: "This permanently deletes the selected rows from the database and can't be undone.")
        switch preview?.outcome {
        case nil:
            return permanent
        case .unavailable:
            return permanent + " "
                + String(localized: "TablePro couldn't check which rows in other tables reference these rows.")
        case .notEnforced:
            return permanent + " "
                + String(localized: "Foreign keys aren't enforced for this save, so rows in other tables that reference these rows stay as they are.")
        case .checked(let lines, let gaps):
            var sentences: [String]
            if !gaps.contains(.checksTurnedOff), lines.contains(where: { $0.kind == .block && $0.count != .unknown }) {
                sentences = [String(localized: "The save will fail: the rows listed below still reference rows this deletes, and their foreign key doesn't allow it.")]
            } else if lines.isEmpty {
                sentences = [permanent]
            } else {
                sentences = [
                    String(localized: "Foreign keys also change the rows listed below. This can't be undone, and Data Rewind can't restore rows a foreign key deletes.")
                ]
            }
            if lines.contains(where: { $0.count == .unknown }) {
                sentences.append(String(localized: "Some rows couldn't be counted, so more rows may change than shown."))
            }
            if gaps.contains(.checksTurnedOff) {
                sentences.append(String(localized: "This save turns foreign key checks off first, so these rows may stay as they are."))
            }
            if gaps.contains(.keyColumnsEdited) {
                sentences.append(String(localized: "This save also edits key columns, and the counts don't include those edits."))
            }
            if gaps.contains(.openTransaction) {
                sentences.append(
                    String(localized: "A transaction is open on this connection, and its uncommitted rows aren't in these counts.")
                )
            }
            if gaps.contains(.tablesPastDepthLimit) {
                sentences.append(
                    String(
                        format: String(localized: "Tables more than %lld foreign keys away weren't checked."),
                        CascadeDeletePlan.maximumDepth
                    )
                )
            }
            if gaps.contains(.keysNotFollowed) {
                sentences.append(String(localized: "Some foreign keys weren't followed, so more rows may change than shown."))
            }
            if gaps.contains(.otherSchemas) {
                sentences.append(String(localized: "Foreign keys declared in other schemas weren't checked."))
            }
            return sentences.joined(separator: " ")
        }
    }

    var lines: [Line] {
        guard case .checked(let lines, _) = preview?.outcome else { return [] }
        return lines.map { line in
            Line(text: Self.text(for: line), table: line.table, filterCondition: line.filterCondition)
        }
    }

    var visibleLines: [Line] {
        Array(lines.prefix(Self.maximumVisibleLines))
    }

    var hiddenLineCount: Int {
        max(lines.count - Self.maximumVisibleLines, 0)
    }

    var confirmButtonTitle: String {
        String(localized: "Delete")
    }

    private static func text(for line: CascadeDeletePreview.Line) -> String {
        let table = line.table
        switch (line.kind, line.count) {
        case (.delete, .rows(1)):
            return String(format: String(localized: "Deletes 1 row from %@"), table)
        case (.delete, .rows(let count)):
            return String(format: String(localized: "Deletes %lld rows from %@"), count, table)
        case (.delete, .unknown):
            return String(format: String(localized: "Deletes rows from %@ (not counted)"), table)
        case (.setNull(let columns), .rows(1)):
            return String(format: String(localized: "Sets %@ to NULL in 1 row of %@"), list(columns), table)
        case (.setNull(let columns), .rows(let count)):
            return String(format: String(localized: "Sets %@ to NULL in %lld rows of %@"), list(columns), count, table)
        case (.setNull(let columns), .unknown):
            return String(format: String(localized: "Sets %@ to NULL in rows of %@ (not counted)"), list(columns), table)
        case (.setDefault(let columns), .rows(1)):
            return String(format: String(localized: "Sets %@ to its default in 1 row of %@"), list(columns), table)
        case (.setDefault(let columns), .rows(let count)):
            return String(format: String(localized: "Sets %@ to its default in %lld rows of %@"), list(columns), count, table)
        case (.setDefault(let columns), .unknown):
            return String(format: String(localized: "Sets %@ to its default in rows of %@ (not counted)"), list(columns), table)
        case (.block, .rows(1)):
            return String(format: String(localized: "1 row in %@ blocks the delete"), table)
        case (.block, .rows(let count)):
            return String(format: String(localized: "%lld rows in %@ block the delete"), count, table)
        case (.block, .unknown):
            return String(format: String(localized: "Rows in %@ may block the delete (not counted)"), table)
        }
    }

    private static func list(_ columns: [String]) -> String {
        columns.joined(separator: ", ")
    }
}

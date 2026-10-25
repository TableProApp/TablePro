import Foundation

struct CellPosition: Hashable {
    let row: Int
    let column: Int
}

enum DataGridChangeVocabulary: Equatable {
    case pendingEdit
    case comparison
    case resultComparison
}

struct RowVisualState: Equatable {
    let isDeleted: Bool
    let isInserted: Bool
    let modifiedColumns: Set<Int>
    let struckColumns: Set<Int>
    // Pending cells staged as SQL, which draw like a pending DEFAULT.
    let expressionColumns: Set<Int>
    let vocabulary: DataGridChangeVocabulary
    let highlight: RowHighlight

    init(
        isDeleted: Bool,
        isInserted: Bool,
        modifiedColumns: Set<Int>,
        struckColumns: Set<Int> = [],
        expressionColumns: Set<Int> = [],
        vocabulary: DataGridChangeVocabulary = .pendingEdit,
        highlight: RowHighlight = .none
    ) {
        self.isDeleted = isDeleted
        self.isInserted = isInserted
        self.modifiedColumns = modifiedColumns
        self.struckColumns = struckColumns
        self.expressionColumns = expressionColumns
        self.vocabulary = vocabulary
        self.highlight = highlight
    }

    func isModified(columnIndex: Int) -> Bool {
        modifiedColumns.contains(columnIndex)
    }

    func isStruck(columnIndex: Int) -> Bool {
        struckColumns.contains(columnIndex)
    }

    func isExpression(columnIndex: Int) -> Bool {
        expressionColumns.contains(columnIndex)
    }

    func highlighted(_ highlight: RowHighlight) -> RowVisualState {
        RowVisualState(
            isDeleted: isDeleted,
            isInserted: isInserted,
            modifiedColumns: modifiedColumns,
            struckColumns: struckColumns,
            expressionColumns: expressionColumns,
            vocabulary: vocabulary,
            highlight: highlight
        )
    }

    static let empty = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [])
}

extension RowVisualState {
    func cellHighlightColor(forColumn column: Int) -> HighlightColor? {
        guard !isDeleted, !isInserted else { return nil }
        return highlight.cellRule(forColumn: column)?.color
    }

    func drawnHighlightRule(forColumn column: Int) -> HighlightRule? {
        guard !isDeleted, !isInserted else { return nil }
        if !isModified(columnIndex: column), let cellRule = highlight.cellRule(forColumn: column) {
            return cellRule
        }
        return highlight.rowRule
    }
}

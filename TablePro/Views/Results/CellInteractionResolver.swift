//
//  CellInteractionResolver.swift
//  TablePro
//

import Foundation

internal struct CellContext: Equatable {
    let columnType: ColumnType?
    let value: String?
    let isTableEditable: Bool
    let isRowDeleted: Bool
    let isImmutableColumn: Bool
    let displayFormatOverride: ValueDisplayFormat?

    init(
        columnType: ColumnType?,
        value: String?,
        isTableEditable: Bool,
        isRowDeleted: Bool,
        isImmutableColumn: Bool,
        displayFormatOverride: ValueDisplayFormat? = nil
    ) {
        self.columnType = columnType
        self.value = value
        self.isTableEditable = isTableEditable
        self.isRowDeleted = isRowDeleted
        self.isImmutableColumn = isImmutableColumn
        self.displayFormatOverride = displayFormatOverride
    }
}

internal enum CellInteractionMode: Equatable {
    case viewInline(value: String)
    case viewJson
    case viewBlob
    case viewPhpSerialized

    case editInline(value: String)
    case editOverlay(value: String)
    case editJson
    case editBlob

    case blocked
}

internal struct CellInteractionResolver {
    func resolve(_ context: CellContext) -> CellInteractionMode {
        guard !context.isRowDeleted else { return .blocked }

        let isReadOnly = !context.isTableEditable || context.isImmutableColumn

        if context.columnType?.isBlobType == true {
            return isReadOnly ? .viewBlob : .editBlob
        }

        switch context.displayFormatOverride {
        case .json:
            return isReadOnly ? .viewJson : .editJson
        case .phpSerialized:
            return .viewPhpSerialized
        case .raw, .uuid, .unixTimestamp, .unixTimestampMillis, .none:
            return plainText(for: context, isReadOnly: isReadOnly)
        }
    }

    private func plainText(for context: CellContext, isReadOnly: Bool) -> CellInteractionMode {
        if isReadOnly {
            return .viewInline(value: context.value ?? "NULL")
        }
        let value = context.value ?? ""
        if value.containsLineBreak { return .editOverlay(value: value) }
        return .editInline(value: value)
    }
}

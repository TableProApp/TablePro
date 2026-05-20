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
}

internal enum CellInteractionMode: Equatable {
    case viewInline(value: String)
    case viewJson
    case viewBlob

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

        if isReadOnly {
            if let columnType = context.columnType {
                if columnType.isBlobType { return .viewBlob }
                if columnType.isJsonType { return .viewJson }
            }
            return .viewInline(value: context.value ?? "NULL")
        }

        if let columnType = context.columnType {
            if columnType.isBlobType { return .editBlob }
            if columnType.isJsonType { return .editJson }
        }

        let value = context.value ?? ""
        if value.containsLineBreak { return .editOverlay(value: value) }
        if value.looksLikeJson { return .editJson }
        return .editInline(value: value)
    }
}

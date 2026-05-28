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
    let columnName: String?
    let connectionId: UUID?
    let tableName: String?
    let displayFormatOverride: ValueDisplayFormat?

    init(
        columnType: ColumnType?,
        value: String?,
        isTableEditable: Bool,
        isRowDeleted: Bool,
        isImmutableColumn: Bool,
        columnName: String? = nil,
        connectionId: UUID? = nil,
        tableName: String? = nil,
        displayFormatOverride: ValueDisplayFormat? = nil
    ) {
        self.columnType = columnType
        self.value = value
        self.isTableEditable = isTableEditable
        self.isRowDeleted = isRowDeleted
        self.isImmutableColumn = isImmutableColumn
        self.columnName = columnName
        self.connectionId = connectionId
        self.tableName = tableName
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
    case editPhpSerialized

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
            if let override = context.displayFormatOverride {
                switch override {
                case .raw:
                    return .viewInline(value: context.value ?? "NULL")
                case .json:
                    return .viewJson
                case .phpSerialized:
                    return .viewPhpSerialized
                case .uuid, .unixTimestamp, .unixTimestampMillis:
                    break
                }
            }
            let value = context.value ?? ""
            switch CellValueContentDetector.detect(value) {
            case .json: return .viewJson
            case .phpSerialized: return .viewPhpSerialized
            case .plain: return .viewInline(value: context.value ?? "NULL")
            }
        }

        if let columnType = context.columnType {
            if columnType.isBlobType { return .editBlob }
            if columnType.isJsonType { return .editJson }
        }

        if let override = context.displayFormatOverride {
            switch override {
            case .raw:
                break
            case .json:
                return .editJson
            case .phpSerialized:
                return .viewPhpSerialized
            case .uuid, .unixTimestamp, .unixTimestampMillis:
                break
            }
        }

        let value = context.value ?? ""
        switch CellValueContentDetector.detect(value) {
        case .json:
            return .editJson
        case .phpSerialized:
            return .viewPhpSerialized
        case .plain:
            if value.containsLineBreak { return .editOverlay(value: value) }
            return .editInline(value: value)
        }
    }
}

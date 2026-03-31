//
//  FieldEditorResolver.swift
//  TablePro

internal enum FieldEditorKind: Equatable {
    case json
    case blobHex
    case boolean
    case enumPicker(values: [String])
    case setPicker(values: [String])
    case multiLine
    case singleLine
}

@MainActor
internal enum FieldEditorResolver {
    static func resolve(for type: ColumnType, isLongText: Bool, originalValue: String?) -> FieldEditorKind {
        if type.isJsonType || (originalValue ?? "").looksLikeJson {
            return .json
        }
        if type.isEnumType, let values = type.enumValues, !values.isEmpty {
            return .enumPicker(values: values)
        }
        if type.isSetType, let values = type.enumValues, !values.isEmpty {
            return .setPicker(values: values)
        }
        if type.isBooleanType {
            return .boolean
        }
        if BlobFormattingService.shared.requiresFormatting(columnType: type) {
            return .blobHex
        }
        if isLongText {
            return .multiLine
        }
        return .singleLine
    }
}

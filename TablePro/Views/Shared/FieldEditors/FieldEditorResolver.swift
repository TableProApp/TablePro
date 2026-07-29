//
//  FieldEditorResolver.swift
//  TablePro

import Foundation

internal enum FieldEditorKind: Equatable {
    case json
    case phpSerialized
    case blobHex
    case boolean
    case enumPicker(values: [String])
    case setPicker(values: [String])
    case multiLine
    case singleLine
}

@MainActor
internal enum FieldEditorResolver {
    static func resolve(
        for type: ColumnType,
        isLongText: Bool,
        originalValue: String?,
        displayFormatOverride: ValueDisplayFormat? = nil
    ) -> FieldEditorKind {
        let structuredAllowed: Bool
        if let override = displayFormatOverride {
            switch override {
            case .raw:
                structuredAllowed = false
            case .phpSerialized:
                return .phpSerialized
            case .json:
                return .json
            case .uuid, .unixTimestamp, .unixTimestampMillis:
                structuredAllowed = true
            }
        } else {
            structuredAllowed = true
        }

        if structuredAllowed {
            if type.isJsonType || (originalValue ?? "").looksLikeJson {
                return .json
            }
            if CellValueContentDetector.detect(originalValue ?? "") == .phpSerialized {
                return .phpSerialized
            }
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

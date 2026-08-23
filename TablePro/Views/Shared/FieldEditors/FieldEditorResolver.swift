//
//  FieldEditorResolver.swift
//  TablePro

import Foundation

@MainActor
internal enum FieldEditorResolver {
    static func resolve(field: FieldEditState) -> FieldEditorKind {
        if let editor = field.editor { return editor }
        return resolve(
            for: field.columnTypeEnum,
            isLongText: field.isLongText,
            originalValue: field.originalValue
        )
    }

    static func resolve(context: FieldEditorContext) -> FieldEditorKind {
        if let editor = context.editor { return editor }
        return resolve(
            for: context.columnType,
            isLongText: context.isLongText,
            originalValue: context.originalValue
        )
    }

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
        if isLongText || needsMultiLineEditor(originalValue) {
            return .multiLine
        }
        return .singleLine
    }

    /// `isLongText` only matches six exact type names, so a large value in `VARCHAR(MAX)`,
    /// `NCLOB` or ClickHouse's `Nullable(String)` never reached the multi-line editor. Whether a
    /// value belongs on one line is a property of the value, so ask the value as well.
    static func needsMultiLineEditor(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let text = value as NSString
        if text.length > multiLineValueThreshold { return true }
        return text.rangeOfCharacter(from: .newlines).location != NSNotFound
    }

    /// Two lines' worth. Between 32 and 46 subheadline characters fit one line at the inspector's
    /// minimum width, so a value past this needs a third line and a short scalar keeps the text
    /// field AppKit intends for it.
    static let multiLineValueThreshold = 80
}

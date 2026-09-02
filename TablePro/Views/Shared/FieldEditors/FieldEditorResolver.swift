//
//  FieldEditorResolver.swift
//  TablePro

import Foundation

@MainActor
internal enum FieldEditorResolver {
    /// Answers from the field's own resolution when it has one. Only a field built before
    /// `MultiRowEditState` filled it in pays the detectors here.
    static func resolve(field: FieldEditState) -> FieldEditorKind {
        if let editor = field.editor { return editor }
        if let resolved = field.resolvedEditor { return resolved }
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
            case .text, .uuid, .unixTimestamp, .unixTimestampMillis:
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

    /// Two lines' worth at the inspector's minimum width. The value font is user-configurable, so how
    /// many characters actually fit a line moves with it; the threshold stays a fixed count on purpose,
    /// because which editor a value gets must not change under the user when they resize the font.
    static let multiLineValueThreshold = 80
}

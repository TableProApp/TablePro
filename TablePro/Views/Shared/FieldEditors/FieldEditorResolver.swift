//
//  FieldEditorResolver.swift
//  TablePro

import Foundation
import TableProPluginKit

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
            if let elementEditor = arrayElementEditor(for: type, originalValue: originalValue) {
                return .arrayElements(element: elementEditor, values: type.enumValues ?? [])
            }
            if type.isJsonType || (originalValue ?? "").looksLikeJson {
                return .json
            }
            switch CellValueContentDetector.detect(originalValue ?? "") {
            case .phpSerialized:
                return .phpSerialized
            case .image(let format):
                return .image(format)
            case .json, .plain:
                break
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

    /// The element editor an array column's value opens on, or nil where the list cannot represent
    /// it and the plain text editor stays.
    ///
    /// The value is parsed, not the type alone: `jsonb[]` and `jsonb[][]` are one type in
    /// PostgreSQL's catalog, and a dimension-prefixed literal such as `[0:2]={a,b,c}` is legal in
    /// any array column, so the declared type cannot rule either out on a given row. This is the
    /// same gate the grid applies before opening the popover.
    ///
    /// It is also what scopes the editor to the engines whose arrays are written this way. The
    /// classifier's `[]` rule takes no engine, and a document store's `object[]` classifies the
    /// same, so a field with no literal to read keeps the plain editor rather than being offered a
    /// list that commits PostgreSQL `{…}` syntax. That leaves a stored NULL and a multi-row
    /// selection on the plain editor, which is where they already were.
    private static func arrayElementEditor(for type: ColumnType, originalValue: String?) -> ArrayElementEditor? {
        guard let elementEditor = type.arrayElementEditor,
              let originalValue,
              PostgresArrayLiteralCodec.parse(originalValue) != nil
        else { return nil }
        return elementEditor
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

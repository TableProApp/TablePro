//
//  ArrayValueEditorModel.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct ArrayEditorRow: Identifiable, Equatable {
    let id: UUID
    var element: PostgresArrayElement

    /// What the server sent for this element, kept beside the edited copy.
    ///
    /// A JSON element is shown pretty-printed, and PostgreSQL stores `json` text verbatim, so
    /// writing the displayed form back would rewrite every element the user never touched. A row
    /// that still means the same JSON emits this instead. Nil on a row the user added.
    let originalElement: PostgresArrayElement?

    init(id: UUID = UUID(), element: PostgresArrayElement, originalElement: PostgresArrayElement? = nil) {
        self.id = id
        self.element = element
        self.originalElement = originalElement
    }
}

enum ArrayValueEditorModel {
    static func rows(from elements: [PostgresArrayElement]) -> [ArrayEditorRow] {
        elements.map { ArrayEditorRow(element: $0, originalElement: $0) }
    }

    static func literal(
        from rows: [ArrayEditorRow],
        delimiter: Character,
        elementEditor: ArrayElementEditor = .scalar
    ) -> String {
        let elements = rows.map { committedElement($0, elementEditor: elementEditor) }
        return PostgresArrayLiteralCodec.serialize(elements, delimiter: delimiter)
    }

    /// The element a row writes back.
    ///
    /// An edited JSON element commits compact, which is what the scalar JSON editor does, and an
    /// unedited one commits the bytes the server sent. The rule is confined to JSON elements
    /// because a scalar array can hold text that happens to parse as JSON, and there retyping the
    /// whitespace inside it is a real edit.
    static func committedElement(
        _ row: ArrayEditorRow,
        elementEditor: ArrayElementEditor
    ) -> PostgresArrayElement {
        guard elementEditor == .json, case .value(let edited) = row.element else { return row.element }
        let normalized = JsonReindenter.normalize(edited)
        if case .value(let stored) = row.originalElement, normalized == JsonReindenter.normalize(stored) {
            return .value(stored)
        }
        return .value(normalized)
    }

    /// What a JSON element shows in the element list.
    ///
    /// A nil summary is SQL NULL, which the list renders as its own state rather than as text that
    /// could be confused with `"null"`.
    struct JsonElementDisplay: Equatable {
        let summary: String?
        let isValid: Bool
    }

    /// Past this, an element is previewed from its first characters and never parsed.
    ///
    /// The list rebuilds on every keystroke in the detail editor, and a parse walks the whole
    /// document, so parsing each visible row's element per render is unbounded work on the main
    /// actor. A preview needs a couple of hundred characters, so the cost is capped at the prefix
    /// rather than at the value. An element too large to check reports no verdict rather than a
    /// wrong one; the detail editor still reports invalid JSON authoritatively.
    private static let maxInspectableLength = 4_096

    static func jsonDisplay(of element: PostgresArrayElement, limit: Int = 200) -> JsonElementDisplay {
        guard case .value(let value) = element else {
            return JsonElementDisplay(summary: nil, isValid: true)
        }
        let text = value as NSString
        guard text.length <= maxInspectableLength else {
            return JsonElementDisplay(summary: truncated(text, limit: limit), isValid: true)
        }
        guard JsonSyntaxParser.parse(value) != nil else {
            return JsonElementDisplay(summary: truncated(text, limit: limit), isValid: false)
        }
        return JsonElementDisplay(
            summary: truncated(JsonReindenter.normalize(value) as NSString, limit: limit),
            isValid: true
        )
    }

    private static func truncated(_ text: NSString, limit: Int) -> String {
        guard text.length > limit else { return text as String }
        return text.substring(to: limit) + "…"
    }

    static func pickerOptions(for element: PostgresArrayElement, allowedValues: [String]) -> [String] {
        guard case .value(let value) = element, !allowedValues.contains(value) else {
            return allowedValues
        }
        return allowedValues + [value]
    }

    static func selectionIndex(for element: PostgresArrayElement, in options: [String]) -> Int {
        guard case .value(let value) = element else { return options.count }
        return options.firstIndex(of: value) ?? options.count
    }

    static func element(atSelectionIndex index: Int, in options: [String]) -> PostgresArrayElement {
        guard options.indices.contains(index) else { return .null }
        return .value(options[index])
    }

    static func moved(_ rows: [ArrayEditorRow], from index: Int, by offset: Int) -> [ArrayEditorRow] {
        let target = index + offset
        guard rows.indices.contains(index), rows.indices.contains(target) else { return rows }
        var updated = rows
        updated.swapAt(index, target)
        return updated
    }

    static func moved(_ rows: [ArrayEditorRow], id: UUID, by offset: Int) -> [ArrayEditorRow] {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return rows }
        return moved(rows, from: index, by: offset)
    }

    static func removing(_ rows: [ArrayEditorRow], id: UUID) -> [ArrayEditorRow] {
        rows.filter { $0.id != id }
    }

    static func isDriftedValue(_ element: PostgresArrayElement, allowedValues: [String]) -> Bool {
        guard !allowedValues.isEmpty, case .value(let value) = element else { return false }
        return !allowedValues.contains(value)
    }
}

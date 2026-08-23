//
//  ArrayValueEditorModel.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct ArrayEditorRow: Identifiable, Equatable {
    let id: UUID
    var element: PostgresArrayElement

    init(id: UUID = UUID(), element: PostgresArrayElement) {
        self.id = id
        self.element = element
    }
}

enum ArrayValueEditorModel {
    static func rows(from elements: [PostgresArrayElement]) -> [ArrayEditorRow] {
        elements.map { ArrayEditorRow(element: $0) }
    }

    static func literal(from rows: [ArrayEditorRow], delimiter: Character) -> String {
        PostgresArrayLiteralCodec.serialize(rows.map(\.element), delimiter: delimiter)
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

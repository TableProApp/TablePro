//
//  FilterOperand.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct FilterOperand: Equatable {
    let text: String
    let number: Decimal?
    let boolean: Bool?
    let isNullLiteral: Bool

    init(_ raw: String, columnType: ColumnType?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        text = raw
        number = Self.number(from: trimmed)
        boolean = StoredBoolean.value(of: trimmed)
        isNullLiteral = Self.allowsNullLiteral(for: columnType) && Self.isNullKeyword(trimmed)
    }

    static func list(_ input: String, columnType: ColumnType?) -> [FilterOperand] {
        listItems(input).map { FilterOperand($0, columnType: columnType) }
    }

    static func listItems(_ input: String) -> [String] {
        input.split(separator: ",", omittingEmptySubsequences: true).compactMap {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static func readsAsNullLiteral(_ text: String, columnType: ColumnType?) -> Bool {
        allowsNullLiteral(for: columnType) && isNullKeyword(text.trimmingCharacters(in: .whitespaces))
    }

    static func number(from text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard PluginNumericLiteral.isValid(trimmed) else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func allowsNullLiteral(for columnType: ColumnType?) -> Bool {
        !ColumnTypeSQLQuoting.isKnownTextLike(columnType)
    }

    private static func isNullKeyword(_ text: String) -> Bool {
        text.caseInsensitiveCompare("NULL") == .orderedSame
    }
}

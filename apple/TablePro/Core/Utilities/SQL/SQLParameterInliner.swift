//
//  SQLParameterInliner.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

// The statement as a person approving it reads it, with each bound value written in. Display only: what runs keeps
// its placeholders and binds the values.
struct SQLParameterInliner {
    static func inline(_ statement: ParameterizedStatement, databaseType: DatabaseType, unbound: String? = nil) -> String {
        let style = PluginMetadataRegistry.shared.snapshot(for: databaseType)?.parameterStyle ?? .questionMark
        let sql = statement.sql as NSString
        // A `?` in a comment, a literal or a quoted name such as "x?" is text, never a placeholder, so placeholders
        // are found where the engine's own lexer finds code.
        let code = SQLCodeProjection.code(
            of: statement.sql,
            grammar: databaseType.lexicalGrammar,
            revealingExecutableComments: true
        ) as NSString
        switch style {
        case .dollar:
            return inlineDollarPlaceholders(sql, code: code, parameters: statement.parameters)
        case .questionMark:
            return inlineQuestionMarkPlaceholders(sql, code: code, parameters: statement.parameters, unbound: unbound)
        }
    }

    static func inline(_ statement: OperationStatement, databaseType: DatabaseType) -> String {
        inline(ParameterizedStatement(sql: statement.sql, parameters: statement.boundValues), databaseType: databaseType)
    }

    // A write pinned by its lookup is shown after the lookup, with the values it binds at save time named.
    static func inline(_ step: DataWriteStep, databaseType: DatabaseType) -> [String] {
        guard let lookup = step.lookup, lookup.pinsRows else { return [inline(step.statement, databaseType: databaseType)] }
        return [
            inline(lookup.query, databaseType: databaseType),
            inline(step.statement, databaseType: databaseType, unbound: "/* found by the query above */"),
        ]
    }

    private static let questionMark = UInt16(UnicodeScalar("?").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let zero = UInt16(UnicodeScalar("0").value)
    private static let nine = UInt16(UnicodeScalar("9").value)

    private static func inlineQuestionMarkPlaceholders(
        _ sql: NSString,
        code: NSString,
        parameters: [Any?],
        unbound: String?
    ) -> String {
        var result = ""
        var paramIndex = 0
        var rangeStart = 0
        let length = min(sql.length, code.length)
        for index in 0..<length where code.character(at: index) == questionMark {
            guard paramIndex < parameters.count || unbound != nil else { break }
            result += sql.substring(with: NSRange(location: rangeStart, length: index - rangeStart))
            result += paramIndex < parameters.count ? formatValue(parameters[paramIndex]) : (unbound ?? "?")
            paramIndex += 1
            rangeStart = index + 1
        }
        return result + sql.substring(from: rangeStart)
    }

    private static func inlineDollarPlaceholders(_ sql: NSString, code: NSString, parameters: [Any?]) -> String {
        var result = ""
        var rangeStart = 0
        let length = min(sql.length, code.length)
        var index = 0
        while index < length {
            // `$1` starts a token; inside a name such as `price$1` it is part of the name.
            guard code.character(at: index) == dollar,
                  index == 0 || !SQLNonCodeSpan.isWordUnit(code.character(at: index - 1))
            else {
                index += 1
                continue
            }
            var end = index + 1
            while end < length, (zero...nine).contains(code.character(at: end)) {
                end += 1
            }
            guard end > index + 1,
                  let number = Int(sql.substring(with: NSRange(location: index + 1, length: end - index - 1))),
                  number >= 1, number <= parameters.count
            else {
                index += 1
                continue
            }
            result += sql.substring(with: NSRange(location: rangeStart, length: index - rangeStart))
            result += formatValue(parameters[number - 1])
            index = end
            rangeStart = end
        }
        return result + sql.substring(from: rangeStart)
    }

    private static func formatValue(_ value: Any?) -> String {
        guard let value else {
            return "NULL"
        }

        switch value {
        case let boolVal as Bool:
            return boolVal ? "TRUE" : "FALSE"
        case let intVal as Int:
            return String(intVal)
        case let int8Val as Int8:
            return String(int8Val)
        case let int16Val as Int16:
            return String(int16Val)
        case let int32Val as Int32:
            return String(int32Val)
        case let int64Val as Int64:
            return String(int64Val)
        case let uintVal as UInt:
            return String(uintVal)
        case let uint8Val as UInt8:
            return String(uint8Val)
        case let uint16Val as UInt16:
            return String(uint16Val)
        case let uint32Val as UInt32:
            return String(uint32Val)
        case let uint64Val as UInt64:
            return String(uint64Val)
        case let floatVal as Float:
            return String(floatVal)
        case let doubleVal as Double:
            return String(doubleVal)
        case let stringVal as String:
            return "'\(escapeString(stringVal))'"
        default:
            return "'\(escapeString(String(describing: value)))'"
        }
    }

    private static func escapeString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''", options: .literal)
    }
}

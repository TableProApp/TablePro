//
//  SQLParameterInliner.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

// The statement as a person approving it reads it, with each bound value written in. Display only: what runs keeps
// its placeholders and binds the values. Copy All takes this text away with no mode declared, so the MySQL family
// spells a value in MySQL's own set, which no backslash rule ends early.
struct SQLParameterInliner {
    static func inline(
        _ statement: ParameterizedStatement,
        databaseType: DatabaseType,
        session: PluginSessionLexicalState? = nil,
        unbound: String? = nil
    ) -> String {
        let style = PluginMetadataRegistry.shared.snapshot(for: databaseType)?.parameterStyle ?? .questionMark
        // Shown, never run: without the session's answer the engine's usual reading spells it as the server reads it.
        let escapes = session.map { SQLLexicalResolver.keptTextStringEscapes(for: databaseType, session: $0) }
            ?? SQLLexicalResolver.driverEscapes(
                SQLLexicalResolver.readings(for: databaseType).execution.stringEscapes,
                for: databaseType
            )
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
            return inlineDollarPlaceholders(sql, code: code, parameters: statement.parameters, escapes: escapes)
        case .questionMark:
            return inlineQuestionMarkPlaceholders(
                sql, code: code, parameters: statement.parameters, unbound: unbound, escapes: escapes
            )
        }
    }

    static func inline(
        _ statement: OperationStatement,
        databaseType: DatabaseType,
        session: PluginSessionLexicalState? = nil
    ) -> String {
        inline(
            ParameterizedStatement(sql: statement.sql, parameters: statement.boundValues),
            databaseType: databaseType,
            session: session
        )
    }

    // A write pinned by its lookup is shown after the lookup, with the values it binds at save time named.
    static func inline(
        _ step: DataWriteStep,
        databaseType: DatabaseType,
        session: PluginSessionLexicalState? = nil
    ) -> [String] {
        guard let lookup = step.lookup, lookup.pinsRows else {
            return [inline(step.statement, databaseType: databaseType, session: session)]
        }
        return [
            inline(lookup.query, databaseType: databaseType, session: session),
            inline(step.statement, databaseType: databaseType, session: session, unbound: "/* found by the query above */"),
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
        unbound: String?,
        escapes: SQLStringEscapes
    ) -> String {
        var result = ""
        var paramIndex = 0
        var rangeStart = 0
        let length = min(sql.length, code.length)
        for index in 0..<length where code.character(at: index) == questionMark {
            guard paramIndex < parameters.count || unbound != nil else { break }
            result += sql.substring(with: NSRange(location: rangeStart, length: index - rangeStart))
            result += paramIndex < parameters.count ? formatValue(parameters[paramIndex], escapes: escapes) : (unbound ?? "?")
            paramIndex += 1
            rangeStart = index + 1
        }
        return result + sql.substring(from: rangeStart)
    }

    private static func inlineDollarPlaceholders(
        _ sql: NSString,
        code: NSString,
        parameters: [Any?],
        escapes: SQLStringEscapes
    ) -> String {
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
            result += formatValue(parameters[number - 1], escapes: escapes)
            index = end
            rangeStart = end
        }
        return result + sql.substring(from: rangeStart)
    }

    private static func formatValue(_ value: Any?, escapes: SQLStringEscapes) -> String {
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
            return SQLQuoting.stringLiteral(stringVal, escapes: escapes)
        default:
            return SQLQuoting.stringLiteral(String(describing: value), escapes: escapes)
        }
    }
}

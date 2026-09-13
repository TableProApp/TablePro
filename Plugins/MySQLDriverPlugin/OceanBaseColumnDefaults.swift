//
//  OceanBaseColumnDefaults.swift
//  MySQLDriverPlugin
//

import Foundation

internal enum OceanBaseColumnDefaults {
    enum Resolution: Equatable {
        case value(String)
        case unverified
    }

    private static let literalOnlyBaseTypes: Set<String> = [
        "TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT",
        "DECIMAL", "DEC", "NUMERIC", "FIXED", "FLOAT", "DOUBLE", "REAL", "YEAR", "BOOL", "BOOLEAN",
        "BIT", "ENUM", "SET"
    ]

    private static let textReportedBinaryBaseTypes: Set<String> = ["BINARY", "VARBINARY"]

    static func catalogDefaultNeedsCreateTable(_ catalogDefault: String?, dataType: String) -> Bool {
        guard let catalogDefault, catalogDefault.contains("(") else { return false }
        guard currentTimestampDefault(catalogDefault, dataType: dataType) == nil else { return false }
        return !literalOnlyBaseTypes.contains(baseType(of: dataType))
    }

    static func currentTimestampDefault(_ catalogDefault: String, dataType: String) -> String? {
        guard mysqlTemporalType(dataType) else { return nil }
        return mysqlCurrentTimestampExpression(catalogDefault, dataType: dataType)
    }

    static func binaryLiteralDefault(_ catalogDefault: String, dataType: String) -> String? {
        guard textReportedBinaryBaseTypes.contains(baseType(of: dataType)) else { return nil }
        return "'\(mysqlEscapeStringLiteral(catalogDefault))'"
    }

    static func defaultClauses(fromCreateTable sql: String) -> [String: String]? {
        let lines = sql.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first, declaresTable(header) else { return nil }
        var clauses: [String: String] = [:]
        for line in lines.dropFirst() {
            var definition = line.drop(while: \.isWhitespace)
            guard let name = columnName(consumingFrom: &definition),
                  let operand = defaultOperand(in: withoutTrailingSeparator(definition))
            else { continue }
            clauses[name] = operand
        }
        return clauses
    }

    static func resolve(clause: String?, catalogDefault: String) -> Resolution {
        guard let clause, clause.uppercased() != "NULL" else { return .unverified }
        if clause.hasPrefix("'") {
            guard let literal = decodedStringLiteral(clause), literal == catalogDefault else { return .unverified }
            return .value("'\(mysqlEscapeStringLiteral(literal))'")
        }
        if clause.hasPrefix("("), clause.hasSuffix(")") {
            guard clause.dropFirst().dropLast() == catalogDefault else { return .unverified }
            return .value(clause)
        }
        guard clause.caseInsensitiveCompare(catalogDefault) == .orderedSame else { return .unverified }
        return .value(clause)
    }

    private static func declaresTable(_ header: Substring) -> Bool {
        let words = header.prefix { $0 != "`" && $0 != "\"" && $0 != "(" }
            .split(whereSeparator: \.isWhitespace)
            .map { $0.uppercased() }
        guard words.first == "CREATE", let tableIndex = words.firstIndex(of: "TABLE") else { return false }
        return !words[..<tableIndex].contains("VIEW")
    }

    private static func columnName(consumingFrom definition: inout Substring) -> String? {
        if let quote = definition.first, quote == "`" || quote == "\"" {
            return MySQLCreateTableScanner.consumeQuotedName(from: &definition, quote: quote)
        }
        guard let first = definition.first, first.isLetter || first.isNumber || first == "_" || first == "$" else {
            return nil
        }
        let name = definition.prefix { !$0.isWhitespace }
        definition = definition.dropFirst(name.count)
        return String(name)
    }

    private static func withoutTrailingSeparator(_ definition: Substring) -> Substring {
        var trimmed = definition
        while let last = trimmed.last, last.isWhitespace {
            trimmed = trimmed.dropLast()
        }
        return trimmed.last == "," ? trimmed.dropLast() : trimmed
    }

    private static func defaultOperand(in definition: Substring) -> String? {
        let tokens = MySQLCreateTableScanner.topLevelTokens(of: definition)
        for (index, token) in tokens.enumerated() {
            let upper = token.uppercased()
            if upper == "DEFAULT" {
                return tokens.indices.contains(index + 1) ? String(tokens[index + 1]) : nil
            }
            if upper.hasPrefix("DEFAULT("), token.count > "DEFAULT".count {
                return String(token.dropFirst("DEFAULT".count))
            }
        }
        return nil
    }

    private static func decodedStringLiteral(_ operand: String) -> String? {
        var characters = Array(operand)
        guard characters.count >= 2, characters.removeFirst() == "'" else { return nil }
        var decoded = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                guard index + 1 < characters.count else { return nil }
                decoded.append(unescaped(characters[index + 1]))
                index += 2
            case "'":
                if index + 1 < characters.count, characters[index + 1] == "'" {
                    decoded.append("'")
                    index += 2
                } else {
                    return index == characters.count - 1 ? decoded : nil
                }
            default:
                decoded.append(character)
                index += 1
            }
        }
        return nil
    }

    private static func unescaped(_ character: Character) -> String {
        switch character {
        case "0": return "\u{0}"
        case "b": return "\u{8}"
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "Z": return "\u{1A}"
        case "%", "_": return "\\\(character)"
        default: return String(character)
        }
    }

    private static func baseType(of dataType: String) -> String {
        let upper = dataType.uppercased()
        let beforeParenthesis = upper.split(separator: "(", maxSplits: 1).first.map(String.init) ?? upper
        return beforeParenthesis.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? beforeParenthesis
    }
}

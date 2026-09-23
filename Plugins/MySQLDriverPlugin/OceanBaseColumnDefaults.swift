//
//  OceanBaseColumnDefaults.swift
//  MySQLDriverPlugin
//

import Foundation

nonisolated internal enum OceanBaseColumnDefaults {
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

    /// The default OceanBase's catalog text stands for, where `SHOW CREATE TABLE` has not settled it.
    ///
    /// The catalog drops the precision `CURRENT_TIMESTAMP(3)` was written with and reports a binary
    /// default as the text it holds, so both are answered before the MySQL reading of a bare catalog.
    static func columnDefault(
        _ catalogDefault: String?,
        extra: String?,
        dataType: String,
        isNullable: Bool
    ) -> String? {
        if let catalogDefault,
           let literal = currentTimestampDefault(catalogDefault, dataType: dataType)
               ?? binaryLiteralDefault(catalogDefault, dataType: dataType) {
            return literal
        }
        return mysqlColumnDefault(.bare(catalogDefault), extra: extra, dataType: dataType, isNullable: isNullable)
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

//
//  OceanBaseColumnDefaults.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProMySQLCore
import TableProSQLQuoting

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

    private static let flavor = MySQLServerFlavor.oceanbase(version: nil)

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
        return SQLQuoting.stringLiteral(catalogDefault, escapes: .mysql)
    }

    // The catalog drops the precision `CURRENT_TIMESTAMP(3)` was written with and reports a binary default as its text.
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
        return mysqlColumnDefault(
            .bare(catalogDefault), extra: extra, dataType: dataType, isNullable: isNullable, flavor: flavor
        )
    }

    static func resolve(clause: String?, catalogDefault: String) -> Resolution {
        guard let clause, clause.uppercased() != "NULL" else { return .unverified }
        if let literal = SQLQuoting.decodedStringLiteral(clause, escapes: .mysql) {
            guard literal == catalogDefault else { return .unverified }
            return .value(SQLQuoting.stringLiteral(literal, escapes: .mysql))
        }
        guard mysqlIsSingleExpression(clause, flavor: flavor) else { return .unverified }
        if clause.hasPrefix("("), clause.hasSuffix(")") {
            guard clause.dropFirst().dropLast() == catalogDefault else { return .unverified }
            return .value(clause)
        }
        guard clause.caseInsensitiveCompare(catalogDefault) == .orderedSame else { return .unverified }
        return .value(clause)
    }

    private static func baseType(of dataType: String) -> String {
        let upper = dataType.uppercased()
        let beforeParenthesis = upper.split(separator: "(", maxSplits: 1).first.map(String.init) ?? upper
        return beforeParenthesis.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? beforeParenthesis
    }
}

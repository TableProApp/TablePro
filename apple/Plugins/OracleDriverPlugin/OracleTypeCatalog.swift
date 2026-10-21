//
//  OracleTypeCatalog.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProSQLVocabulary

internal enum OracleTypeCatalog {
    static let columnTypesByCategory: [String: [String]] = Dictionary(
        uniqueKeysWithValues: SQLEngineVocabulary.oracleDataTypeCategories.map { ($0.name, $0.types) }
    )

    /// DATE holds a time of day to the second, so the app has to classify it as a timestamp; classified by its name it
    /// reads as a calendar date, and the grid, export, copy and compare all drop the time. `TIMESTAMP(0)` is the type
    /// with exactly DATE's range and precision.
    static let dateClassificationTypeName = "TIMESTAMP(0)"

    /// The name a result column is classified by, or nil where its declared name classifies the same. Result headers
    /// are the core's lowercase Oracle names.
    static func resultClassificationTypeName(forHeaderType typeName: String) -> String? {
        baseTypeName(typeName) == "DATE" ? dateClassificationTypeName : nil
    }

    /// Result column hints in the shape `PluginQueryResult.columnMeta` carries, or nil when no column needs one, so a
    /// result with nothing to say keeps reporting no metadata.
    static func resultColumnMeta(columns: [String], typeNames: [String]) -> [PluginColumnInfo]? {
        guard columns.count == typeNames.count else { return nil }
        let hints = typeNames.map(resultClassificationTypeName(forHeaderType:))
        guard hints.contains(where: { $0 != nil }) else { return nil }
        return columns.indices.map { index in
            PluginColumnInfo(
                name: columns[index],
                dataType: typeNames[index],
                isNullable: true,
                isPrimaryKey: false,
                defaultValue: nil,
                extra: nil,
                charset: nil,
                collation: nil,
                comment: nil,
                identityKind: nil,
                isGenerated: false,
                allowedValues: nil,
                generationExpression: nil,
                generationKind: nil,
                ddlSpelling: nil,
                ddlDefault: nil,
                ddlGenerationExpression: nil,
                ddlCollation: nil,
                classificationTypeName: hints[index]
            )
        }
    }

    /// The spelling a `CREATE TABLE` has to write for a column whose declared type names another schema's type or a
    /// `REF`, or nil where `dataType` already is that spelling. Such a type is classified by its bare name, so the
    /// declared spelling would otherwise be lost to the DDL writer.
    static func ddlSpelling(forDeclaredType declared: String) -> String? {
        let trimmed = declared.trimmingCharacters(in: .whitespaces)
        let isQualified = trimmed.hasPrefix("\"")
        let isReference = trimmed.uppercased().hasPrefix("REF ")
        return isQualified || isReference ? trimmed : nil
    }

    /// The type a column name reads as for matching: uppercased, every parenthesized modifier removed and spaces
    /// collapsed, so `TIMESTAMP(6) WITH TIME ZONE`, `timestamp with time zone` and `TIMESTAMP WITH TIME ZONE` agree.
    /// Matching only the part before the first parenthesis would read the first of those as a plain `TIMESTAMP`.
    static func baseTypeName(_ typeName: String) -> String {
        var result = ""
        var depth = 0
        for character in typeName.uppercased() {
            switch character {
            case "(":
                depth += 1
            case ")":
                depth = max(depth - 1, 0)
            default:
                guard depth == 0 else { continue }
                result.append(character)
            }
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension PluginQueryResult {
    /// The same result with the Oracle classification hints its columns need, for a result built without them.
    func withOracleClassificationHints() -> PluginQueryResult {
        guard columnMeta == nil,
              let hints = OracleTypeCatalog.resultColumnMeta(columns: columns, typeNames: columnTypeNames) else {
            return self
        }
        var hinted = PluginQueryResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: rowsAffected,
            timing: timing,
            isTruncated: isTruncated,
            statusMessage: statusMessage,
            columnMeta: hints
        )
        hinted.rowLocators = rowLocators
        hinted.absentCells = absentCells
        return hinted
    }
}

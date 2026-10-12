//
//  DuckDBIndexClauses.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProPluginKit

enum DuckDBIndexClauses {
    struct KeyParts: Equatable {
        let columns: [String]
        let expressions: [String]
    }

    static func keyParts(ofCreateIndex sql: String?) -> KeyParts {
        let features = DuckDBLexicalFeatures.features
        guard let sql, let statement = SQLIndexKeyList.statement(sql, lexicalFeatures: features) else {
            return KeyParts(columns: [], expressions: [])
        }
        var expressions: [String] = []
        let columns = statement.keyParts.map { part -> String in
            if let expression = SQLIndexKeyList.unwrapped(part, lexicalFeatures: features) {
                expressions.append(expression)
                return expression
            }
            return SQLIndexKeyList.quotedIdentifier(part, lexicalFeatures: features) ?? part
        }
        return KeyParts(columns: columns, expressions: expressions)
    }

    static func createStatement(
        for index: PluginIndexDefinition,
        qualifiedTable: String,
        quote: (String) -> String
    ) -> String {
        let expressions = Set(index.expressions ?? [])
        let keys = index.columns
            .map { expressions.contains($0) ? "(\($0))" : quote($0) }
            .joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        return "CREATE \(unique)INDEX \(quote(index.name)) ON \(qualifiedTable) (\(keys))"
    }
}

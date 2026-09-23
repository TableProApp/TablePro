//
//  PostgreSQLCatalogBoolean.swift
//  PostgreSQLDriverPlugin
//

import Foundation

nonisolated enum PostgreSQLCatalogBoolean {
    private static let trueSpellings: Set<String> = ["t", "true", "yes", "on", "1"]

    static func isTrue(_ text: String?) -> Bool {
        guard let text else { return false }
        return trueSpellings.contains(text.lowercased())
    }
}

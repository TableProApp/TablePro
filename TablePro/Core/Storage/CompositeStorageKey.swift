//
//  CompositeStorageKey.swift
//  TablePro
//

import Foundation

enum CompositeStorageKey {
    static func make(
        connectionId: UUID,
        databaseName: String,
        schemaName: String?,
        tableName: String
    ) -> String {
        [connectionId.uuidString, databaseName, schemaName ?? "", tableName]
            .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 }
            .joined(separator: ".")
    }
}

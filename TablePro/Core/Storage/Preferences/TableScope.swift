//
//  TableScope.swift
//  TablePro
//

import Foundation

struct TableScope: Hashable, Codable, Sendable {
    let connectionId: UUID
    let database: String?
    let schema: String?
    let table: String

    init(connectionId: UUID, database: String?, schema: String?, table: String) {
        self.connectionId = connectionId
        self.database = database
        self.schema = schema
        self.table = table
    }

    var storageComponent: String {
        [connectionId.uuidString, database ?? "", schema ?? "", table]
            .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 }
            .joined(separator: ".")
    }
}

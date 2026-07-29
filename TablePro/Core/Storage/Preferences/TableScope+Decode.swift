//
//  TableScope+Decode.swift
//  TablePro
//

import Foundation

extension TableScope {
    init?(storageComponent: String) {
        let parts = storageComponent
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 4 else { return nil }

        let decoded = parts.map { $0.removingPercentEncoding ?? $0 }
        guard let connectionId = UUID(uuidString: decoded[0]) else { return nil }

        self.init(
            connectionId: connectionId,
            database: decoded[1].isEmpty ? nil : decoded[1],
            schema: decoded[2].isEmpty ? nil : decoded[2],
            table: decoded[3]
        )
    }

    var displayName: String {
        [database, schema, table]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ".")
    }
}

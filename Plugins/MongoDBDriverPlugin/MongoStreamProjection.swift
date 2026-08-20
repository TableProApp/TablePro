//
//  MongoStreamProjection.swift
//  MongoDBDriverPlugin
//
//  Keeps streamed documents aligned to the column set announced in the stream header.
//

import Foundation
import TableProPluginKit

struct MongoStreamProjection {
    static let sampleSize = 200

    let columns: [String]
    let columnTypeNames: [String]
    let kinds: [BsonValueKind]

    init(columns: [String], columnTypeNames: [String], kinds: [BsonValueKind] = []) {
        guard !columns.isEmpty else {
            self.columns = ["_id"]
            self.columnTypeNames = ["VARCHAR"]
            self.kinds = [.string]
            return
        }

        self.columns = columns
        self.columnTypeNames = columns.indices.map { index in
            index < columnTypeNames.count ? columnTypeNames[index] : "VARCHAR"
        }
        self.kinds = columns.indices.map { index in
            index < kinds.count ? kinds[index] : .string
        }
    }

    var header: PluginStreamHeader {
        PluginStreamHeader(columns: columns, columnTypeNames: columnTypeNames)
    }

    func row(
        for document: [String: Any],
        convert: (Any, BsonValueKind) -> PluginCellValue
    ) -> [PluginCellValue] {
        columns.indices.map { index in
            guard let value = document[columns[index]] else { return .null }
            return convert(value, kinds[index])
        }
    }
}

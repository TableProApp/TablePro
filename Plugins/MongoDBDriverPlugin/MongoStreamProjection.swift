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

    init(columns: [String], columnTypeNames: [String]) {
        guard !columns.isEmpty else {
            self.columns = ["_id"]
            self.columnTypeNames = ["VARCHAR"]
            return
        }

        self.columns = columns
        self.columnTypeNames = columns.indices.map { index in
            index < columnTypeNames.count ? columnTypeNames[index] : "VARCHAR"
        }
    }

    var header: PluginStreamHeader {
        PluginStreamHeader(columns: columns, columnTypeNames: columnTypeNames)
    }

    func row(for document: [String: Any], convert: (Any) -> PluginCellValue) -> [PluginCellValue] {
        columns.map { column in
            guard let value = document[column] else { return .null }
            return convert(value)
        }
    }
}

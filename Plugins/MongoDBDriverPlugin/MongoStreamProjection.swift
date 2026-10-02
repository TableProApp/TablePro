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
    private let announced: Set<String>

    init(columns: [String], columnTypeNames: [String], kinds: [BsonValueKind] = []) {
        guard !columns.isEmpty else {
            self.columns = ["_id"]
            self.columnTypeNames = ["VARCHAR"]
            self.kinds = [.string]
            self.announced = ["_id"]
            return
        }

        self.columns = columns
        self.announced = Set(columns)
        self.columnTypeNames = columns.indices.map { index in
            index < columnTypeNames.count ? columnTypeNames[index] : "VARCHAR"
        }
        self.kinds = columns.indices.map { index in
            index < kinds.count ? kinds[index] : .string
        }
    }

    init(sample: [[String: Any]], census: MongoFieldCensus?, representation: MongoDBUuidRepresentation) {
        let sampled = BsonDocumentFlattener.unionColumns(from: sample)
        let sampledKinds = BsonDocumentFlattener.columnKinds(
            for: sampled, documents: sample, representation: representation
        )
        let typedInSample = BsonDocumentFlattener.heldKinds(in: sample, representation: representation)
        let censusKinds = census?.kinds(representation: representation) ?? [:]
        let known = Set(sampled)
        let unsampled = (census?.fields ?? []).filter { !known.contains($0) }

        let resolvedSampledKinds: [BsonValueKind] = zip(sampled, sampledKinds).map { field, sampledKind in
            guard typedInSample[field] == nil else { return sampledKind }
            return censusKinds[field] ?? sampledKind
        }
        let unsampledKinds: [BsonValueKind] = unsampled.map { censusKinds[$0] ?? .string }
        let kinds = resolvedSampledKinds + unsampledKinds
        self.init(
            columns: sampled + unsampled,
            columnTypeNames: kinds.map { BsonDocumentFlattener.typeName(for: $0, representation: representation) },
            kinds: kinds
        )
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

    func unannouncedFields(in document: [String: Any]) -> [String] {
        document.keys.filter { !announced.contains($0) }
    }
}

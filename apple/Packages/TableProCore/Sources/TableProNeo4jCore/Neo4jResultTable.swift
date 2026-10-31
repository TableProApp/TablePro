import Foundation

public struct Neo4jResultTable: Equatable, Sendable {
    public let columns: [String]
    public let typeNames: [String]
    public let rows: [[String?]]

    public init(columns: [String], typeNames: [String], rows: [[String?]]) {
        self.columns = columns
        self.typeNames = typeNames
        self.rows = rows
    }

    public static func records(keys: [String], records: [[PackStreamValue]]) -> Neo4jResultTable {
        let typeNames = keys.indices.map { index -> String in
            for record in records where index < record.count && record[index] != .null {
                return Neo4jValueText.typeName(record[index])
            }
            return "ANY"
        }
        let rows = records.map { record in
            keys.indices.map { index in index < record.count ? Neo4jValueText.text(record[index]) : nil }
        }
        return Neo4jResultTable(columns: keys, typeNames: typeNames, rows: rows)
    }

    // Known keys keep their order; keys first seen on this page follow, sorted. A stream's columns are fixed by its
    // header, so it passes `addsUnseenProperties: false`.
    public static func entities(
        kind: Neo4jEntityKind,
        records: [[PackStreamValue]],
        knownProperties: [String],
        addsUnseenProperties: Bool = true
    ) -> Neo4jResultTable {
        let entities = records.compactMap { $0.first.flatMap(Neo4jEntity.init) }
        let known = Set(knownProperties)
        let extra = addsUnseenProperties ? Set(entities.flatMap(\.properties.keys)).subtracting(known).sorted() : []
        let properties = knownProperties + extra
        let fixed = Neo4jCypher.fixedColumns(for: kind)

        var typeNames = fixed.map { _ in "STRING" }
        if kind == .node { typeNames[1] = "LIST" }
        for key in properties {
            let sample = entities.lazy.compactMap { $0.properties[key] }.first { $0 != .null }
            typeNames.append(sample.map(Neo4jValueText.typeName) ?? "ANY")
        }

        let rows = entities.map { entity -> [String?] in
            var row: [String?] = [entity.elementId]
            switch entity.kind {
            case .node(let labels):
                row.append(Neo4jValueText.text(.list(labels.map(PackStreamValue.string))))
            case .relationship(_, let startId, let endId):
                row.append(startId)
                row.append(endId)
            }
            row += properties.map { entity.properties[$0].flatMap(Neo4jValueText.text) }
            return row
        }
        return Neo4jResultTable(columns: fixed + properties, typeNames: typeNames, rows: rows)
    }
}

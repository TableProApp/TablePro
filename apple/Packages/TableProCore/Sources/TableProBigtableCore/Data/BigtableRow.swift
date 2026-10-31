import Foundation

public struct BigtableColumn: Hashable, Sendable, Comparable {
    public let family: String
    public let qualifier: Data

    public init(family: String, qualifier: Data) {
        self.family = family
        self.qualifier = qualifier
    }

    /// `family:qualifier`, the way `cbt` and the console name a column. A family name cannot hold a
    /// colon, so the first one always splits the two.
    public var name: String {
        family + ":" + BigtableBytes.display(qualifier)
    }

    // By scalar: a qualifier that starts with a combining mark joins the colon into one Character.
    public init(name: String) throws {
        guard let colon = name.unicodeScalars.firstIndex(of: ":"), colon != name.startIndex else {
            throw BigtableError.configuration(String(
                format: String(localized: "\"%@\" is not a column. Name it as family:qualifier."), name
            ))
        }
        self.family = String(name.unicodeScalars[..<colon])
        let scalars = name.unicodeScalars
        self.qualifier = try BigtableBytes.parse(String(scalars[scalars.index(after: colon)...]))
    }

    public static func < (lhs: BigtableColumn, rhs: BigtableColumn) -> Bool {
        lhs.family == rhs.family ? lhs.qualifier.lexicographicallyPrecedes(rhs.qualifier) : lhs.family < rhs.family
    }
}

public struct BigtableCell: Equatable, Sendable {
    public let value: Data
    public let timestampMicros: Int64

    public init(value: Data, timestampMicros: Int64) {
        self.value = value
        self.timestampMicros = timestampMicros
    }
}

/// A row with the newest version of each cell.
public struct BigtableRow: Equatable, Sendable {
    public let key: Data
    public let cells: [BigtableColumn: BigtableCell]

    public init(key: Data, cells: [BigtableColumn: BigtableCell]) {
        self.key = key
        self.cells = cells
    }
}

/// Rebuilds rows from the `chunks` of a `ReadRows` response. Family and qualifier carry over from
/// the chunk before when a chunk leaves them out, a value larger than one chunk arrives in pieces
/// marked by `valueSize`, and `resetRow` throws away the row in progress.
public struct BigtableChunkAssembler {
    private var rows: [BigtableRow] = []
    private var key: Data?
    private var cells: [BigtableColumn: BigtableCell] = [:]
    private var family: String?
    private var qualifier: Data?
    private var timestamp: Int64 = 0
    private var value = Data()
    private var inCell = false

    public init() {}

    public static func rows(fromResponse json: Any, operation: String) throws -> [BigtableRow] {
        let messages = json as? [[String: Any]] ?? (json as? [String: Any]).map { [$0] } ?? []
        var assembler = BigtableChunkAssembler()
        for message in messages {
            if let error = message["error"] as? [String: Any] {
                throw BigtableError.from(streamError: error, operation: operation)
            }
            for chunk in message["chunks"] as? [[String: Any]] ?? [] {
                try assembler.add(chunk)
            }
        }
        return try assembler.finish()
    }

    public mutating func add(_ chunk: [String: Any]) throws {
        if chunk["resetRow"] as? Bool == true {
            resetRow()
            return
        }
        if let encodedKey = chunk["rowKey"] as? String {
            let newKey = try BigtableBytes.decodeBase64(encodedKey)
            if let key, key != newKey, !cells.isEmpty || inCell {
                throw BigtableError.malformedResponse(String(localized: "Bigtable started a new row before committing the last one."))
            }
            key = newKey
        }
        if let name = Self.string(chunk["familyName"]) {
            family = name
            qualifier = nil
        }
        if let encoded = Self.string(chunk["qualifier"]) {
            qualifier = try BigtableBytes.decodeBase64(encoded)
        }
        if !inCell {
            timestamp = Self.int64(chunk["timestampMicros"]) ?? 0
            value = Data()
        }
        if let encoded = chunk["value"] as? String {
            value.append(try BigtableBytes.decodeBase64(encoded))
        }
        inCell = (Self.int64(chunk["valueSize"]) ?? 0) > 0
        if !inCell, let family, let qualifier {
            let column = BigtableColumn(family: family, qualifier: qualifier)
            if cells[column].map({ $0.timestampMicros < timestamp }) ?? true {
                cells[column] = BigtableCell(value: value, timestampMicros: timestamp)
            }
        }
        if chunk["commitRow"] as? Bool == true {
            guard let key, !inCell else {
                throw BigtableError.malformedResponse(String(localized: "Bigtable committed a row it never started."))
            }
            rows.append(BigtableRow(key: key, cells: cells))
            resetRow()
        }
    }

    public func finish() throws -> [BigtableRow] {
        guard !inCell, cells.isEmpty else {
            throw BigtableError.malformedResponse(String(localized: "Bigtable ended the response in the middle of a row."))
        }
        return rows
    }

    private mutating func resetRow() {
        key = nil
        cells = [:]
        family = nil
        qualifier = nil
        value = Data()
        inCell = false
    }

    /// `familyName` and `qualifier` are wrapper messages, which JSON writes as the bare value but a
    /// proxy may still write as `{"value": ...}`.
    private static func string(_ any: Any?) -> String? {
        if let text = any as? String { return text }
        return (any as? [String: Any])?["value"] as? String
    }

    private static func int64(_ any: Any?) -> Int64? {
        switch any {
        case let text as String: return Int64(text)
        case let number as NSNumber: return number.int64Value
        default: return nil
        }
    }
}

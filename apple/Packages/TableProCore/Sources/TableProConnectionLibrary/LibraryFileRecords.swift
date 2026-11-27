import Foundation

// A record this build cannot decode is kept as it was read, so a save writes it back instead of dropping it.
public struct LibraryFileRecords<Element: Decodable> {
    public let elements: [Element]
    public let unreadable: [UnreadableLibraryRecord]

    // Throws only when the data is not a JSON array.
    public init(decoding data: Data, using decoder: JSONDecoder = JSONDecoder()) throws {
        var elements: [Element] = []
        var unreadable: [UnreadableLibraryRecord] = []
        for entry in try decoder.decode([LibraryFileEntry<Element>].self, from: data) {
            switch entry {
            case .decoded(let element):
                elements.append(element)
            case .unreadable(let record):
                unreadable.append(record)
            }
        }
        self.elements = elements
        self.unreadable = unreadable
    }

    // The same check the decoding init makes, so data that passes always loads.
    public static func isList(_ data: Data) -> Bool {
        (try? JSONDecoder().decode([UnreadableLibraryRecord].self, from: data)) != nil
    }
}

public enum LibraryFileError: Error, Equatable {
    case idHeldByUnreadableRecord(UUID)
}

public extension LibraryFileRecords where Element: Encodable {
    // A kept record is never written over, since this build would re-encode it without what it cannot read: a save
    // carrying its id is refused. `removing` drops kept records by id, as a deletion another device made does.
    static func encoded(
        _ elements: [Element],
        keeping unreadable: [UnreadableLibraryRecord],
        removing removedIds: Set<UUID> = [],
        using encoder: JSONEncoder = JSONEncoder()
    ) throws -> (data: Data, kept: [UnreadableLibraryRecord]) {
        let kept = unreadable.filter { record in record.id.map { !removedIds.contains($0) } ?? true }
        let keptIds = Set(kept.compactMap(\.id))
        if !keptIds.isEmpty {
            let saved = try JSONDecoder().decode([UnreadableLibraryRecord].self, from: encoder.encode(elements))
            if let taken = saved.lazy.compactMap(\.id).first(where: keptIds.contains) {
                throw LibraryFileError.idHeldByUnreadableRecord(taken)
            }
        }
        let data = try encoder.encode(elements.map(LibraryFileEntry.decoded) + kept.map(LibraryFileEntry.unreadable))
        return (data, kept)
    }
}

// Integers decode before doubles so ids and ports keep their precision.
public enum UnreadableLibraryRecord: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([UnreadableLibraryRecord])
    case object([String: UnreadableLibraryRecord])

    // What the app keeps for a record, such as its secrets, stays while this build cannot read the record.
    public var id: UUID? {
        guard case .object(let fields) = self, case .string(let text)? = fields["id"] else { return nil }
        return UUID(uuidString: text)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([UnreadableLibraryRecord].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: UnreadableLibraryRecord].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

private enum LibraryFileEntry<Element: Decodable>: Decodable {
    case decoded(Element)
    case unreadable(UnreadableLibraryRecord)

    init(from decoder: any Decoder) throws {
        if let element = try? Element(from: decoder) {
            self = .decoded(element)
        } else {
            self = .unreadable(try UnreadableLibraryRecord(from: decoder))
        }
    }
}

extension LibraryFileEntry: Encodable where Element: Encodable {
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .decoded(let element):
            try element.encode(to: encoder)
        case .unreadable(let record):
            try record.encode(to: encoder)
        }
    }
}

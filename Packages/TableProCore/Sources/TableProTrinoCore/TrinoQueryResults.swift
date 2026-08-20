import Foundation

public struct TrinoTypeSignature: Decodable, Sendable, Equatable {
    public let rawType: String

    public init(rawType: String) {
        self.rawType = rawType
    }

    private enum CodingKeys: String, CodingKey {
        case rawType
    }
}

public struct TrinoColumn: Decodable, Sendable, Equatable {
    public let name: String
    public let type: String
    public let typeSignature: TrinoTypeSignature?

    public init(name: String, type: String, typeSignature: TrinoTypeSignature? = nil) {
        self.name = name
        self.type = type
        self.typeSignature = typeSignature
    }

    public var rawTypeName: String {
        if let raw = typeSignature?.rawType, !raw.isEmpty {
            return raw
        }
        return TrinoTypeMapper.baseType(fromDisplayType: type)
    }

    public var category: TrinoTypeCategory {
        TrinoTypeMapper.category(forRawType: rawTypeName)
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, typeSignature
    }
}

public struct TrinoStats: Decodable, Sendable, Equatable {
    public let state: String?

    private enum CodingKeys: String, CodingKey {
        case state
    }
}

public struct TrinoQueryResults: Decodable, Sendable {
    public let id: String
    public let infoUri: String?
    public let partialCancelUri: String?
    public let nextUri: String?
    public let columns: [TrinoColumn]?
    public let data: [[TrinoJSONValue]]?
    public let error: TrinoQueryError?
    public let updateType: String?
    public let updateCount: Int?
    public let stats: TrinoStats?

    private enum CodingKeys: String, CodingKey {
        case id, infoUri, partialCancelUri, nextUri, columns, data, error, updateType, updateCount, stats
    }
}

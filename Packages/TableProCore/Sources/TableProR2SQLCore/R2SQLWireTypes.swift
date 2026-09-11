import Foundation

public struct R2SQLRequestBody: Encodable, Sendable, Equatable {
    public let query: String

    public init(query: String) {
        self.query = query
    }
}

/// The envelope every R2 SQL response arrives in.
///
/// Decoded strictly: a body that does not match is a `malformedResponse`, never an empty result.
/// Decoding every field with `try?` is what let a changed wire shape come back as a successful
/// query with no columns.
public struct R2SQLEnvelope: Decodable, Sendable, Equatable {
    public let success: Bool
    public let errors: [R2SQLAPIError]
    public let result: R2SQLResult?

    private enum CodingKeys: String, CodingKey {
        case success, errors, result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        errors = try container.decodeIfPresent([R2SQLAPIError].self, forKey: .errors) ?? []
        result = try container.decodeIfPresent(R2SQLResult.self, forKey: .result)
    }
}

public struct R2SQLResult: Decodable, Sendable, Equatable {
    public let schema: [R2SQLField]
    public let rows: [[String: R2SQLJSONValue]]

    public init(schema: [R2SQLField], rows: [[String: R2SQLJSONValue]]) {
        self.schema = schema
        self.rows = rows
    }

    private enum CodingKeys: String, CodingKey {
        case schema, rows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent([R2SQLField].self, forKey: .schema) ?? []
        rows = try container.decodeIfPresent([[String: R2SQLJSONValue]].self, forKey: .rows) ?? []
    }
}

/// One output column, as `{"name": ..., "descriptor": {"type": {"name": ...}, "nullable": ...}}`.
public struct R2SQLField: Decodable, Sendable, Equatable {
    public let name: String
    public let typeName: String
    public let isNullable: Bool

    public init(name: String, typeName: String, isNullable: Bool = true) {
        self.name = name
        self.typeName = typeName
        self.isNullable = isNullable
    }

    private enum CodingKeys: String, CodingKey {
        case name, descriptor
    }

    private enum DescriptorKeys: String, CodingKey {
        case type, nullable
    }

    private enum TypeKeys: String, CodingKey {
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let descriptor = try container.nestedContainer(keyedBy: DescriptorKeys.self, forKey: .descriptor)
        let type = try descriptor.nestedContainer(keyedBy: TypeKeys.self, forKey: .type)
        typeName = try type.decode(String.self, forKey: .name)
        isNullable = try descriptor.decodeIfPresent(Bool.self, forKey: .nullable) ?? true
    }
}

public struct R2SQLHTTPRequest: Sendable, Equatable {
    public let url: URL
    public let headers: [String: String]
    public let body: Data
    public let timeoutInterval: TimeInterval

    public init(url: URL, headers: [String: String], body: Data, timeoutInterval: TimeInterval) {
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutInterval = timeoutInterval
    }
}

public struct R2SQLHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol R2SQLTransport: Sendable {
    func send(_ request: R2SQLHTTPRequest) async throws -> R2SQLHTTPResponse
    func cancelAll()
}

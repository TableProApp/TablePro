import Foundation

public struct R2SQLRequestBody: Encodable, Sendable, Equatable {
    public let warehouse: String
    public let query: String

    public init(warehouse: String, query: String) {
        self.warehouse = warehouse
        self.query = query
    }
}

public struct R2SQLField: Decodable, Sendable, Equatable {
    public let name: String
    public let rawType: R2SQLJSONValue?

    public init(name: String, rawType: R2SQLJSONValue?) {
        self.name = name
        self.rawType = rawType
    }

    public init(name: String, type: String) {
        self.init(name: name, rawType: .string(type))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        rawType = try? container.decodeIfPresent(R2SQLJSONValue.self, forKey: .type)
    }

    public var typeName: String {
        switch rawType {
        case .string(let value):
            return value
        case .object(let fields):
            if case .string(let value)? = fields["name"] { return value }
            return ""
        case .none, .null:
            return ""
        default:
            return rawType?.scalarText ?? ""
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, type
    }
}

public struct R2SQLMetrics: Decodable, Sendable, Equatable {
    public let r2RequestsCount: Int?
    public let filesScanned: Int?
    public let bytesScanned: Int?

    private enum CodingKeys: String, CodingKey {
        case r2RequestsCount = "r2_requests_count"
        case filesScanned = "files_scanned"
        case bytesScanned = "bytes_scanned"
    }
}

public struct R2SQLResult: Decodable, Sendable, Equatable {
    public let requestId: String?
    public let schema: [R2SQLField]
    public let rows: [[String: R2SQLJSONValue]]
    public let metrics: R2SQLMetrics?

    public init(
        requestId: String? = nil,
        schema: [R2SQLField],
        rows: [[String: R2SQLJSONValue]],
        metrics: R2SQLMetrics? = nil
    ) {
        self.requestId = requestId
        self.schema = schema
        self.rows = rows
        self.metrics = metrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)
        schema = (try? container.decodeIfPresent([R2SQLField].self, forKey: .schema)) ?? []
        rows = (try? container.decodeIfPresent([[String: R2SQLJSONValue]].self, forKey: .rows)) ?? []
        metrics = try? container.decodeIfPresent(R2SQLMetrics.self, forKey: .metrics)
    }

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case schema, rows, metrics
    }
}

public struct R2SQLEnvelope: Decodable, Sendable, Equatable {
    public let result: R2SQLResult?
    public let success: Bool
    public let errors: [R2SQLAPIError]
    public let messages: [String]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try? container.decodeIfPresent(R2SQLResult.self, forKey: .result)
        success = (try? container.decodeIfPresent(Bool.self, forKey: .success)) ?? false
        errors = (try? container.decodeIfPresent([R2SQLAPIError].self, forKey: .errors)) ?? []
        messages = (try? container.decodeIfPresent([String].self, forKey: .messages)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case result, success, errors, messages
    }
}

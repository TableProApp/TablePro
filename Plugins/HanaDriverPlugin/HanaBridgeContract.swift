import Foundation
import TableProPluginKit

struct HanaConnectConfiguration: Encodable, Equatable, Sendable {
    enum TLSMode: String, Encodable, Sendable {
        case disabled
        case preferred
        case required
        case verifyCa
        case verifyIdentity

        init(_ mode: SSLMode) {
            switch mode {
            case .disabled: self = .disabled
            case .preferred: self = .preferred
            case .required: self = .required
            case .verifyCa: self = .verifyCa
            case .verifyIdentity: self = .verifyIdentity
            }
        }
    }

    static let defaultConnectTimeoutSeconds: Double = 30

    let host: String
    let port: Int
    let username: String
    let password: String
    let schema: String
    let tlsMode: TLSMode
    let tlsServerName: String
    let caCertificatePath: String
    let clientCertificatePath: String
    let clientKeyPath: String
    let connectTimeoutSeconds: Double
}

enum HanaBridgeCell: Equatable, Sendable, Codable {
    case null
    case text(String)
    case bytes(Data)

    private enum CodingKeys: String, CodingKey {
        case bytes
    }

    init(_ value: PluginCellValue) {
        switch value {
        case .null: self = .null
        case .text(let text): self = .text(text)
        case .bytes(let data): self = .bytes(data)
        }
    }

    init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
            return
        }
        if let text = try? single.decode(String.self) {
            self = .text(text)
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try keyed.decode(String.self, forKey: .bytes)
        guard let data = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                forKey: .bytes,
                in: keyed,
                debugDescription: "The bytes cell is not valid base64."
            )
        }
        self = .bytes(data)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var single = encoder.singleValueContainer()
            try single.encodeNil()
        case .text(let text):
            var single = encoder.singleValueContainer()
            try single.encode(text)
        case .bytes(let data):
            var keyed = encoder.container(keyedBy: CodingKeys.self)
            try keyed.encode(data.base64EncodedString(), forKey: .bytes)
        }
    }

    var pluginValue: PluginCellValue {
        switch self {
        case .null: return .null
        case .text(let text): return .text(text)
        case .bytes(let data): return .bytes(data)
        }
    }
}

struct HanaExecuteRequest: Encodable, Sendable {
    let sql: String
    let parameters: [HanaBridgeCell]?
    let rowCap: Int
    let timeoutSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case sql, parameters, rowCap, timeoutSeconds
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sql, forKey: .sql)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(rowCap, forKey: .rowCap)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
    }
}

struct HanaExplainRequest: Encodable, Sendable {
    let sql: String
    let timeoutSeconds: Int
}

struct HanaConnectResult: Decodable, Equatable, Sendable {
    let serverVersion: String
    let currentSchema: String
    let connectionId: Int64
}

struct HanaResultEnvelope: Decodable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case columns, columnTypeNames, columnClassifications, rows, rowsAffected, hasResultSet, executionTime
        case isTruncated, truncatedLobCount, sessionLost
    }

    let columns: [String]
    let columnTypeNames: [String]
    let columnClassifications: [String?]
    let rows: [[HanaBridgeCell]]
    let rowsAffected: Int64
    let hasResultSet: Bool
    let executionTime: TimeInterval
    let isTruncated: Bool
    let truncatedLobCount: Int
    let sessionLost: Bool

    init(
        columns: [String],
        columnTypeNames: [String],
        columnClassifications: [String?],
        rows: [[HanaBridgeCell]],
        rowsAffected: Int64,
        hasResultSet: Bool,
        executionTime: TimeInterval,
        isTruncated: Bool,
        truncatedLobCount: Int,
        sessionLost: Bool = false
    ) {
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.columnClassifications = columnClassifications
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.hasResultSet = hasResultSet
        self.executionTime = executionTime
        self.isTruncated = isTruncated
        self.truncatedLobCount = truncatedLobCount
        self.sessionLost = sessionLost
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try container.decode([String].self, forKey: .columns)
        columnTypeNames = try container.decode([String].self, forKey: .columnTypeNames)
        columnClassifications = try container.decode([String?].self, forKey: .columnClassifications)
        rows = try container.decode([[HanaBridgeCell]].self, forKey: .rows)
        rowsAffected = try container.decode(Int64.self, forKey: .rowsAffected)
        hasResultSet = try container.decode(Bool.self, forKey: .hasResultSet)
        executionTime = try container.decode(TimeInterval.self, forKey: .executionTime)
        isTruncated = try container.decode(Bool.self, forKey: .isTruncated)
        truncatedLobCount = try container.decode(Int.self, forKey: .truncatedLobCount)
        sessionLost = try container.decodeIfPresent(Bool.self, forKey: .sessionLost) ?? false
    }
}

struct HanaBridgeFailure: Error, Decodable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case server
        case cancelled
        case timeout
        case connectionLost
        case closed
        case parameter
        case tls
        case configuration
        case connect
        case internalFailure = "internal"
    }

    enum TLSCode: Int, Sendable {
        case untrustedCertificate = 1
        case hostnameMismatch = 2
        case serverRequiresPlaintext = 3
        case clientCredentialsUnreadable = 4
    }

    private enum CodingKeys: String, CodingKey {
        case kind, code, position, message, parameter, expected
    }

    let kind: Kind
    let code: Int
    let position: Int
    let message: String
    let parameter: Int
    let expected: String

    static let closed = HanaBridgeFailure(kind: .closed)

    init(
        kind: Kind,
        code: Int = 0,
        position: Int = 0,
        message: String = "",
        parameter: Int = 0,
        expected: String = ""
    ) {
        self.kind = kind
        self.code = code
        self.position = position
        self.message = message
        self.parameter = parameter
        self.expected = expected
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        kind = Kind(rawValue: rawKind) ?? .internalFailure
        code = try container.decodeIfPresent(Int.self, forKey: .code) ?? 0
        position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        parameter = try container.decodeIfPresent(Int.self, forKey: .parameter) ?? 0
        expected = try container.decodeIfPresent(String.self, forKey: .expected) ?? ""
    }

    static func decoded(from data: Data) -> HanaBridgeFailure {
        guard let failure = try? JSONDecoder().decode(HanaBridgeFailure.self, from: data) else {
            return HanaBridgeFailure(kind: .internalFailure, message: String(bytes: data, encoding: .utf8) ?? "")
        }
        return failure
    }
}

//
//  DynamoDBConnection.swift
//  DynamoDBDriverPlugin
//
//  AWS DynamoDB HTTP client with Signature V4 authentication.
//

import CommonCrypto
import Foundation
import os
import TableProPluginKit

// MARK: - DynamoDB Attribute Value

indirect enum DynamoDBAttributeValue: Sendable, Equatable {
    case string(String)
    case number(String)
    case binary(Data)
    case bool(Bool)
    case null
    case list([DynamoDBAttributeValue])
    case map([String: DynamoDBAttributeValue])
    case stringSet([String])
    case numberSet([String])
    case binarySet([Data])
}

extension DynamoDBAttributeValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamoDBTypeCodingKey.self)

        if let value = try container.decodeIfPresent(String.self, forKey: .s) {
            self = .string(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .n) {
            self = .number(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .b) {
            guard let data = Data(base64Encoded: value) else {
                throw DecodingError.dataCorruptedError(forKey: .b, in: container, debugDescription: "Invalid base64 string")
            }
            self = .binary(data)
        } else if let value = try container.decodeIfPresent(Bool.self, forKey: .bool) {
            self = .bool(value)
        } else if let value = try container.decodeIfPresent(Bool.self, forKey: .null), value {
            self = .null
        } else if let items = try container.decodeIfPresent([DynamoDBAttributeValue].self, forKey: .l) {
            self = .list(items)
        } else if let map = try container.decodeIfPresent([String: DynamoDBAttributeValue].self, forKey: .m) {
            self = .map(map)
        } else if let values = try container.decodeIfPresent([String].self, forKey: .ss) {
            self = .stringSet(values)
        } else if let values = try container.decodeIfPresent([String].self, forKey: .ns) {
            self = .numberSet(values)
        } else if let values = try container.decodeIfPresent([String].self, forKey: .bs) {
            let decoded = try values.map { str -> Data in
                guard let data = Data(base64Encoded: str) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .bs, in: container,
                        debugDescription: "Invalid base64 string in binary set"
                    )
                }
                return data
            }
            self = .binarySet(decoded)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown DynamoDB attribute type"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamoDBTypeCodingKey.self)

        switch self {
        case .string(let value):
            try container.encode(value, forKey: .s)
        case .number(let value):
            try container.encode(value, forKey: .n)
        case .binary(let value):
            try container.encode(value.base64EncodedString(), forKey: .b)
        case .bool(let value):
            try container.encode(value, forKey: .bool)
        case .null:
            try container.encode(true, forKey: .null)
        case .list(let items):
            try container.encode(items, forKey: .l)
        case .map(let map):
            try container.encode(map, forKey: .m)
        case .stringSet(let values):
            try container.encode(values, forKey: .ss)
        case .numberSet(let values):
            try container.encode(values, forKey: .ns)
        case .binarySet(let values):
            try container.encode(values.map { $0.base64EncodedString() }, forKey: .bs)
        }
    }
}

private enum DynamoDBTypeCodingKey: String, CodingKey {
    case s = "S"
    case n = "N"
    case b = "B"
    case bool = "BOOL"
    case null = "NULL"
    case l = "L"
    case m = "M"
    case ss = "SS"
    case ns = "NS"
    case bs = "BS"
}

// MARK: - DynamoDB Error

internal enum DynamoDBError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case serverError(String)
    case authFailed(String)
    case requestCancelled
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to DynamoDB")
        case .connectionFailed(let detail):
            return String(format: String(localized: "Connection failed: %@"), detail)
        case .serverError(let detail):
            return String(format: String(localized: "DynamoDB error: %@"), detail)
        case .authFailed(let detail):
            return String(format: String(localized: "Authentication failed: %@"), detail)
        case .requestCancelled:
            return String(localized: "Request was cancelled")
        case .invalidResponse(let detail):
            return String(format: String(localized: "Invalid response: %@"), detail)
        }
    }
}

// MARK: - Response Types

internal struct ListTablesResponse: Decodable {
    let TableNames: [String]?
    let LastEvaluatedTableName: String?
}

internal struct DescribeTableResponse: Decodable {
    let Table: TableDescription
}

internal struct TableDescription: Decodable {
    let TableName: String
    let KeySchema: [KeySchemaElement]?
    let AttributeDefinitions: [AttributeDefinition]?
    let GlobalSecondaryIndexes: [GlobalSecondaryIndexDescription]?
    let LocalSecondaryIndexes: [LocalSecondaryIndexDescription]?
    let ProvisionedThroughput: ProvisionedThroughputDescription?
    let BillingModeSummary: BillingModeSummary?
    let ItemCount: Int64?
    let TableSizeBytes: Int64?
    let TableStatus: String?
    let TableArn: String?
    let CreationDateTime: Double?
}

internal struct KeySchemaElement: Decodable {
    let AttributeName: String
    let KeyType: String
}

internal struct AttributeDefinition: Decodable {
    let AttributeName: String
    let AttributeType: String
}

internal struct GlobalSecondaryIndexDescription: Decodable {
    let IndexName: String
    let KeySchema: [KeySchemaElement]?
    let Projection: Projection?
    let IndexStatus: String?
    let ProvisionedThroughput: ProvisionedThroughputDescription?
    let ItemCount: Int64?
    let IndexSizeBytes: Int64?
}

internal struct LocalSecondaryIndexDescription: Decodable {
    let IndexName: String
    let KeySchema: [KeySchemaElement]?
    let Projection: Projection?
    let ItemCount: Int64?
    let IndexSizeBytes: Int64?
}

internal struct ProvisionedThroughputDescription: Decodable {
    let ReadCapacityUnits: Int64?
    let WriteCapacityUnits: Int64?
}

internal struct BillingModeSummary: Decodable {
    let BillingMode: String?
}

internal struct Projection: Decodable {
    let ProjectionType: String?
    let NonKeyAttributes: [String]?
}

internal struct ScanResponse: Decodable {
    let Items: [[String: DynamoDBAttributeValue]]?
    let Count: Int?
    let ScannedCount: Int?
    let LastEvaluatedKey: [String: DynamoDBAttributeValue]?
}

internal struct QueryResponse: Decodable {
    let Items: [[String: DynamoDBAttributeValue]]?
    let Count: Int?
    let ScannedCount: Int?
    let LastEvaluatedKey: [String: DynamoDBAttributeValue]?
}

internal struct ExecuteStatementResponse: Decodable {
    let Items: [[String: DynamoDBAttributeValue]]?
    let NextToken: String?
    let LastEvaluatedKey: [String: DynamoDBAttributeValue]?
}

private struct DynamoDBErrorResponse: Decodable {
    let __type: String?
    let message: String?
    let Message: String?

    var errorMessage: String {
        message ?? Message ?? __type ?? "Unknown error"
    }
}

// MARK: - DynamoDB Connection

internal final class DynamoDBConnection: @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var _session: URLSession?
    private var _credentials: AWSCredentials?
    private var _currentTask: URLSessionDataTask?
    private let _queryTimeout = HttpQueryTimeoutBox()
    private let region: String
    private let endpointUrl: String
    private static let logger = Logger(subsystem: "com.TablePro", category: "DynamoDBConnection")
    private static let service = "dynamodb"

    var session: URLSession? {
        lock.withLock { _session }
    }

    func setQueryTimeout(_ seconds: Int) {
        _queryTimeout.set(serverTimeoutSeconds: seconds)
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        self.region = config.additionalFields["awsRegion"] ?? "us-east-1"

        if let customEndpoint = config.additionalFields["awsEndpointUrl"], !customEndpoint.isEmpty {
            if customEndpoint.lowercased().hasPrefix("http://") {
                let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
                let isLoopback = URL(string: customEndpoint).flatMap(\.host).map {
                    loopbackHosts.contains($0.lowercased())
                } ?? false
                if isLoopback {
                    self.endpointUrl = customEndpoint
                } else {
                    let upgraded = "https://" + customEndpoint.dropFirst("http://".count)
                    Self.logger.warning("Insecure endpoint for non-loopback host, upgrading to HTTPS")
                    self.endpointUrl = upgraded
                }
            } else {
                self.endpointUrl = customEndpoint
            }
        } else {
            self.endpointUrl = "https://dynamodb.\(region).amazonaws.com"
        }
    }

    func connect() async throws {
        let credentials = try await resolveCredentials()
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = HttpQueryTimeout.sessionBootstrapRequestTimeout
        sessionConfig.timeoutIntervalForResource = HttpQueryTimeout.sessionResourceTimeout
        let urlSession = URLSession(configuration: sessionConfig)

        lock.withLock {
            _credentials = credentials
            _session = urlSession
        }

        // Verify connectivity by listing tables with limit 1
        _ = try await listTables(limit: 1)
    }

    func disconnect() {
        lock.withLock {
            _currentTask?.cancel()
            _currentTask = nil
            // Don't invalidate the session — in-flight health monitor pings may still
            // hold a reference. Just nil it out; URLSession cleans up on dealloc.
            _session = nil
            _credentials = nil
        }
    }

    func ping() async throws {
        _ = try await listTables(limit: 1)
    }

    func cancelCurrentRequest() {
        lock.withLock {
            _currentTask?.cancel()
            _currentTask = nil
        }
    }

    // MARK: - DynamoDB API Operations

    func listTables(limit: Int = 100, exclusiveStartTableName: String? = nil) async throws -> ListTablesResponse {
        var body: [String: Any] = ["Limit": limit]
        if let startName = exclusiveStartTableName {
            body["ExclusiveStartTableName"] = startName
        }
        return try await request(target: "DynamoDB_20120810.ListTables", body: body)
    }

    func describeTable(tableName: String) async throws -> DescribeTableResponse {
        let body: [String: Any] = ["TableName": tableName]
        return try await request(target: "DynamoDB_20120810.DescribeTable", body: body)
    }

    func scan(
        tableName: String,
        limit: Int? = nil,
        exclusiveStartKey: [String: DynamoDBAttributeValue]? = nil,
        select: String? = nil
    ) async throws -> ScanResponse {
        var body: [String: Any] = ["TableName": tableName]
        if let limit = limit {
            body["Limit"] = limit
        }
        if let startKey = exclusiveStartKey {
            body["ExclusiveStartKey"] = try encodedAttributeMap(startKey)
        }
        if let select = select {
            body["Select"] = select
        }
        return try await request(target: "DynamoDB_20120810.Scan", body: body)
    }

    func query(
        tableName: String,
        keyConditionExpression: String,
        expressionAttributeValues: [String: DynamoDBAttributeValue],
        limit: Int? = nil,
        exclusiveStartKey: [String: DynamoDBAttributeValue]? = nil,
        scanIndexForward: Bool = true,
        select: String? = nil
    ) async throws -> QueryResponse {
        var body: [String: Any] = [
            "TableName": tableName,
            "KeyConditionExpression": keyConditionExpression,
            "ExpressionAttributeValues": try encodedAttributeMap(expressionAttributeValues)
        ]
        if let limit = limit {
            body["Limit"] = limit
        }
        if let startKey = exclusiveStartKey {
            body["ExclusiveStartKey"] = try encodedAttributeMap(startKey)
        }
        body["ScanIndexForward"] = scanIndexForward
        if let select = select {
            body["Select"] = select
        }
        return try await request(target: "DynamoDB_20120810.Query", body: body)
    }

    func executeStatement(
        statement: String,
        parameters: [[String: Any]]? = nil,
        limit: Int? = nil,
        nextToken: String? = nil
    ) async throws -> ExecuteStatementResponse {
        var body: [String: Any] = ["Statement": statement]
        if let parameters = parameters, !parameters.isEmpty {
            body["Parameters"] = parameters
        }
        if let limit = limit {
            body["Limit"] = limit
        }
        if let nextToken = nextToken {
            body["NextToken"] = nextToken
        }
        return try await request(target: "DynamoDB_20120810.ExecuteStatement", body: body)
    }

    // MARK: - Internal Request Handling

    private func request<T: Decodable>(target: String, body: [String: Any]) async throws -> T {
        let urlSession: URLSession = try lock.withLock {
            guard let s = _session else { throw DynamoDBError.notConnected }
            return s
        }
        let credentials = try await validCredentials()

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        guard let url = URL(string: endpointUrl) else {
            throw DynamoDBError.connectionFailed("Invalid endpoint URL: \(endpointUrl)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(target, forHTTPHeaderField: "X-Amz-Target")
        let hostHeader: String
        if let host = url.host, let port = url.port {
            hostHeader = "\(host):\(port)"
        } else {
            hostHeader = url.host ?? ""
        }
        urlRequest.setValue(hostHeader, forHTTPHeaderField: "Host")

        signRequest(&urlRequest, body: bodyData, credentials: credentials)
        urlRequest.timeoutInterval = _queryTimeout.requestTimeoutInterval

        let (data, response) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = urlSession.dataTask(with: urlRequest) { [weak self] data, response, error in
                self?.lock.withLock { self?._currentTask = nil }
                if let error {
                    if (error as? URLError)?.code == .cancelled {
                        continuation.resume(throwing: DynamoDBError.requestCancelled)
                    } else {
                        continuation.resume(throwing: DynamoDBError.connectionFailed(error.localizedDescription))
                    }
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: DynamoDBError.invalidResponse("Empty response"))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            self.lock.withLock { self._currentTask = task }
            task.resume()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DynamoDBError.invalidResponse("Not an HTTP response")
        }

        if httpResponse.statusCode != 200 {
            if let errorResponse = try? JSONDecoder().decode(DynamoDBErrorResponse.self, from: data) {
                let errorType = errorResponse.__type ?? "UnknownError"
                if errorType.contains("UnrecognizedClientException") ||
                    errorType.contains("InvalidSignatureException") ||
                    errorType.contains("AccessDeniedException")
                {
                    throw DynamoDBError.authFailed(errorResponse.errorMessage)
                }
                throw DynamoDBError.serverError("[\(errorType)] \(errorResponse.errorMessage)")
            }
            throw DynamoDBError.serverError("HTTP \(httpResponse.statusCode): Response body redacted (length: \(data.count))")
        }

        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            return decoded
        } catch {
            Self.logger.error("Decode failed for \(target): responseLength=\(data.count), error=\(error.localizedDescription)")
            throw DynamoDBError.invalidResponse("Failed to decode response: \(error.localizedDescription)")
        }
    }

    // MARK: - AWS Signature V4

    private func signRequest(_ request: inout URLRequest, body: Data, credentials: AWSCredentials) {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: now)

        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: now)

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")

        if let sessionToken = credentials.sessionToken, !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        let host = request.value(forHTTPHeaderField: "Host") ?? request.url?.host ?? ""
        let method = request.httpMethod ?? "POST"
        let uri = request.url?.path ?? "/"
        let canonicalUri = uri.isEmpty ? "/" : uri
        let canonicalQuerystring = request.url?.query ?? ""

        // Signed headers: content-type, host, x-amz-date, and optionally x-amz-security-token
        var signedHeaderNames = ["content-type", "host", "x-amz-date"]
        var canonicalHeaders = "content-type:\(request.value(forHTTPHeaderField: "Content-Type") ?? "")\n"
        canonicalHeaders += "host:\(host)\n"
        canonicalHeaders += "x-amz-date:\(amzDate)\n"

        if let sessionToken = credentials.sessionToken, !sessionToken.isEmpty {
            signedHeaderNames.append("x-amz-security-token")
            canonicalHeaders += "x-amz-security-token:\(sessionToken)\n"
        }

        let signedHeaders = signedHeaderNames.joined(separator: ";")
        let payloadHash = sha256Hex(body)

        let canonicalRequest = [
            method,
            canonicalUri,
            canonicalQuerystring,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(Self.service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(
            secretKey: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: Self.service
        )
        let signature = hmacSHA256Hex(key: signingKey, data: Data(stringToSign.utf8))

        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(credentialScope), " +
            "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private func deriveSigningKey(secretKey: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        return kSigning
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyPtr.baseAddress, key.count,
                    dataPtr.baseAddress, data.count,
                    &result
                )
            }
        }
        return Data(result)
    }

    private func hmacSHA256Hex(key: Data, data: Data) -> String {
        hmacSHA256(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Credential Resolution

    private func resolveCredentials() async throws -> AWSCredentials {
        let source = Self.credentialSource(forAuthMethod: config.additionalFields["awsAuthMethod"])
        var fields = config.additionalFields
        if (fields["awsAccessKeyId"] ?? "").isEmpty, !config.username.isEmpty {
            fields["awsAccessKeyId"] = config.username
        }
        if (fields["awsSecretAccessKey"] ?? "").isEmpty, !config.password.isEmpty {
            fields["awsSecretAccessKey"] = config.password
        }

        do {
            return try await AWSCredentialResolver.resolve(source: source, fields: fields)
        } catch let error as AWSAuthError {
            throw DynamoDBError.authFailed(error.localizedDescription)
        } catch let error as AWSSSOError {
            throw DynamoDBError.authFailed(error.localizedDescription)
        }
    }

    static func credentialSource(forAuthMethod authMethod: String?) -> String {
        switch authMethod {
        case "profile":
            return "profile"
        case "sso":
            return "sso"
        default:
            return "accessKey"
        }
    }

    private func validCredentials() async throws -> AWSCredentials {
        if let current = lock.withLock({ _credentials }), !current.isExpired() {
            return current
        }
        let refreshed = try await resolveCredentials()
        lock.withLock { _credentials = refreshed }
        return refreshed
    }

    // MARK: - Helpers

    private func encodedAttributeMap(_ map: [String: DynamoDBAttributeValue]) throws -> [String: Any] {
        let encoder = JSONEncoder()
        var result: [String: Any] = [:]
        for (key, value) in map {
            let data = try encoder.encode(value)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result[key] = json
            }
        }
        return result
    }
}

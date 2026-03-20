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

// MARK: - AWS Credentials

internal struct AWSCredentials: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
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
            return String(localized: "Connection failed: \(detail)")
        case .serverError(let detail):
            return String(localized: "DynamoDB error: \(detail)")
        case .authFailed(let detail):
            return String(localized: "Authentication failed: \(detail)")
        case .requestCancelled:
            return String(localized: "Request was cancelled")
        case .invalidResponse(let detail):
            return String(localized: "Invalid response: \(detail)")
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

private struct SsoProfileSettings {
    let accountId: String
    let roleName: String
    let startUrl: String
    let ssoSession: String?
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
    private let region: String
    private let endpointUrl: String
    private static let logger = Logger(subsystem: "com.TablePro", category: "DynamoDBConnection")
    private static let service = "dynamodb"

    var session: URLSession? {
        lock.withLock { _session }
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
        let credentials = try resolveCredentials()
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
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
        let (urlSession, credentials): (URLSession, AWSCredentials) = try lock.withLock {
            guard let s = _session else { throw DynamoDBError.notConnected }
            guard let c = _credentials else { throw DynamoDBError.authFailed("No credentials available") }
            return (s, c)
        }

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

    private func resolveCredentials() throws -> AWSCredentials {
        let authMethod = config.additionalFields["awsAuthMethod"] ?? "credentials"

        switch authMethod {
        case "credentials":
            return try resolveAccessKeyCredentials()
        case "profile":
            return try resolveProfileCredentials()
        case "sso":
            return try resolveSsoCredentials()
        default:
            return try resolveAccessKeyCredentials()
        }
    }

    private func resolveAccessKeyCredentials() throws -> AWSCredentials {
        let accessKeyId = config.additionalFields["awsAccessKeyId"] ?? config.username
        let secretAccessKey = config.additionalFields["awsSecretAccessKey"] ?? config.password
        let sessionToken = config.additionalFields["awsSessionToken"]

        Self.logger.debug("Resolved credentials — credentialSource: accessKey, region: \(self.region)")

        guard !accessKeyId.isEmpty, !secretAccessKey.isEmpty else {
            throw DynamoDBError.authFailed("Access Key ID and Secret Access Key are required")
        }

        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken?.isEmpty == true ? nil : sessionToken
        )
    }

    private func resolveProfileCredentials() throws -> AWSCredentials {
        let profileName = config.additionalFields["awsProfileName"] ?? "default"
        let credentialsPath = NSString("~/.aws/credentials").expandingTildeInPath

        guard let content = try? String(contentsOfFile: credentialsPath, encoding: .utf8) else {
            throw DynamoDBError.authFailed("Cannot read ~/.aws/credentials")
        }

        var currentProfile = ""
        var accessKeyId = ""
        var secretAccessKey = ""
        var sessionToken: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentProfile = String(trimmed.dropFirst().dropLast())
                continue
            }
            guard currentProfile == profileName else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }

            switch parts[0] {
            case "aws_access_key_id":
                accessKeyId = parts[1]
            case "aws_secret_access_key":
                secretAccessKey = parts[1]
            case "aws_session_token":
                sessionToken = parts[1]
            default:
                break
            }
        }

        guard !accessKeyId.isEmpty, !secretAccessKey.isEmpty else {
            throw DynamoDBError.authFailed("Profile '\(profileName)' not found or incomplete in ~/.aws/credentials")
        }

        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken
        )
    }

    private func resolveSsoCredentials() throws -> AWSCredentials {
        let profileName = config.additionalFields["awsProfileName"] ?? "default"
        let ssoSettings = try parseSsoProfileSettings(profileName: profileName)
        let cliCachePath = NSString("~/.aws/cli/cache").expandingTildeInPath

        // Compute the expected cache filename from the profile's SSO settings.
        // The AWS CLI caches credentials using SHA1 of a minified JSON with sorted keys.
        let cacheKey: String
        if let sessionName = ssoSettings.ssoSession {
            // Session-based SSO: {"accountId":"...","roleName":"...","sessionName":"..."}
            cacheKey = "{\"accountId\":\"\(ssoSettings.accountId)\",\"roleName\":\"\(ssoSettings.roleName)\",\"sessionName\":\"\(sessionName)\"}"
        } else {
            // Legacy SSO: {"accountId":"...","roleName":"...","startUrl":"..."}
            cacheKey = "{\"accountId\":\"\(ssoSettings.accountId)\",\"roleName\":\"\(ssoSettings.roleName)\",\"startUrl\":\"\(ssoSettings.startUrl)\"}"
        }

        let cacheFileName = sha1Hex(Data(cacheKey.utf8)) + ".json"
        let cacheFilePath = (cliCachePath as NSString).appendingPathComponent(cacheFileName)

        guard let data = FileManager.default.contents(atPath: cacheFilePath) else {
            throw DynamoDBError.authFailed(
                "SSO cache file not found for profile '\(profileName)' at \(cacheFilePath). Run 'aws sso login --profile \(profileName)' first."
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DynamoDBError.authFailed("Invalid SSO cache file for profile '\(profileName)'")
        }

        guard let accessKeyId = json["AccessKeyId"] as? String,
              let secretAccessKey = json["SecretAccessKey"] as? String,
              let sessionToken = json["SessionToken"] as? String
        else {
            throw DynamoDBError.authFailed(
                "SSO cache file for profile '\(profileName)' is missing credential fields. Run 'aws sso login --profile \(profileName)' first."
            )
        }

        if let expiresAtStr = json["Expiration"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let expiresAt = formatter.date(from: expiresAtStr) ?? ISO8601DateFormatter().date(from: expiresAtStr),
               expiresAt <= Date()
            {
                throw DynamoDBError.authFailed(
                    "SSO credentials for profile '\(profileName)' have expired. Run 'aws sso login --profile \(profileName)' to refresh."
                )
            }
        }

        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken
        )
    }

    /// Parse SSO settings from ~/.aws/config for the given profile.
    private func parseSsoProfileSettings(profileName: String) throws -> SsoProfileSettings {
        let configPath = NSString("~/.aws/config").expandingTildeInPath
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            throw DynamoDBError.authFailed("Cannot read ~/.aws/config")
        }

        // In ~/.aws/config, the default profile is [default], others are [profile <name>]
        let targetSection = profileName == "default" ? "default" : "profile \(profileName)"

        var currentSection = ""
        var accountId: String?
        var roleName: String?
        var startUrl: String?
        var ssoSession: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                continue
            }
            guard currentSection == targetSection else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }

            switch parts[0] {
            case "sso_account_id":
                accountId = parts[1]
            case "sso_role_name":
                roleName = parts[1]
            case "sso_start_url":
                startUrl = parts[1]
            case "sso_session":
                ssoSession = parts[1]
            default:
                break
            }
        }

        guard let resolvedAccountId = accountId, let resolvedRoleName = roleName else {
            throw DynamoDBError.authFailed(
                "Profile '\(profileName)' in ~/.aws/config is missing sso_account_id or sso_role_name"
            )
        }

        // startUrl is required for legacy SSO (when sso_session is not set)
        let resolvedStartUrl = startUrl ?? ""
        if ssoSession == nil && resolvedStartUrl.isEmpty {
            throw DynamoDBError.authFailed(
                "Profile '\(profileName)' in ~/.aws/config is missing sso_start_url (required for legacy SSO)"
            )
        }

        return SsoProfileSettings(
            accountId: resolvedAccountId,
            roleName: resolvedRoleName,
            startUrl: resolvedStartUrl,
            ssoSession: ssoSession
        )
    }

    private func sha1Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
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

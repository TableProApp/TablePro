//
//  D1HttpClient.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

// MARK: - API Response Types

nonisolated struct D1ApiResponse<T: Decodable>: Decodable {
    let result: T?
    let success: Bool
    let errors: [D1ApiErrorDetail]?

    private enum CodingKeys: String, CodingKey {
        case result, success, errors
    }
}

nonisolated struct D1ApiErrorDetail: Decodable {
    let code: Int?
    let message: String

    private enum CodingKeys: String, CodingKey {
        case code, message
    }
}

nonisolated struct D1RawResultPayload: Decodable {
    let results: D1RawResults
    let meta: D1QueryMeta?
    let success: Bool

    private enum CodingKeys: String, CodingKey {
        case results, meta, success
    }
}

nonisolated struct D1RawResults: Decodable {
    let columns: [String]?
    let rows: [[D1Value]]?

    private enum CodingKeys: String, CodingKey {
        case columns, rows
    }
}


nonisolated struct D1QueryMeta: Decodable {
    let duration: Double?
    let changes: Int?
    let rowsRead: Int?
    let rowsWritten: Int?

    private enum CodingKeys: String, CodingKey {
        case duration, changes
        case rowsRead = "rows_read"
        case rowsWritten = "rows_written"
    }
}

nonisolated struct D1DatabaseInfo: Decodable, Sendable, Hashable {
    let uuid: String
    let name: String
    let createdAt: String?
    let version: String?

    private enum CodingKeys: String, CodingKey {
        case uuid, name, version
        case createdAt = "created_at"
    }
}

nonisolated struct D1ListResponse: Decodable {
    let result: [D1DatabaseInfo]
    let success: Bool
    let resultInfo: D1ResultInfo?

    private enum CodingKeys: String, CodingKey {
        case result, success
        case resultInfo = "result_info"
    }
}

nonisolated struct D1ResultInfo: Decodable {
    let perPage: Int?
    let totalCount: Int?

    private enum CodingKeys: String, CodingKey {
        case perPage = "per_page"
        case totalCount = "total_count"
    }
}

// SQLite has no boolean storage class, so D1 sends a boolean as 0 or 1; a JSON true or false, which never decodes as
// Int, still reads as 1 or 0. D1's Worker API documents a BLOB as an array of its byte values. Any other JSON keeps its
// text, so a value in a shape nobody expected is still shown instead of reading as NULL.
nonisolated enum D1Value: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bytes(Data)
    case null

    var cellValue: PluginCellValue {
        switch self {
        case .string(let val): return .text(val)
        case .int(let val): return .text(String(val))
        case .double(let val): return .text(String(val))
        case .bytes(let val): return .bytes(val)
        case .null: return .null
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        // Int before Double, so an integer past 2^53 keeps every digit.
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
            return
        }

        if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
            return
        }

        if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
            return
        }

        if let boolVal = try? container.decode(Bool.self) {
            self = .int(boolVal ? 1 : 0)
            return
        }

        if let byteValues = try? container.decode([UInt8].self) {
            self = .bytes(Data(byteValues))
            return
        }

        let json = try container.decode(D1JSONText.self)
        let text = try D1JSONText.compact(json)
        self = .string(text)
    }
}

/// Any JSON value, read only to be written back as text.
nonisolated private enum D1JSONText: Codable {
    case null
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case array([D1JSONText])
    case object([String: D1JSONText])

    // Decodable never sees the source text, so an object's keys come back sorted rather than in the order D1 sent.
    static func compact(_ value: D1JSONText) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        // JSONEncoder writes UTF-8 only, so the fallback is never taken.
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([D1JSONText].self) {
            self = .array(value)
        } else {
            let value = try container.decode([String: D1JSONText].self)
            self = .object(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - HTTP Client

/// Sends with `URLSession.data(for:delegate:)`, so cancelling the Swift task that awaits a request
/// cancels its URL task, and keeps every request in flight so `cancelAll` stops each one. The app
/// runs sidebar and autocomplete reads on this client while a query runs, so a single stored task
/// handle cancelled whichever request started last instead of the query the user stopped.
nonisolated final class D1HttpClient: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "D1HttpClient")

    /// Cloudflare's documented maximum. One page then holds nearly every account, and each page is a request out of
    /// the account's shared quota of 1,200 per five minutes.
    static let databasesPerPage = 10_000

    /// A server that keeps answering full pages cannot hold the caller in a loop past this many requests.
    static let databaseListPageLimit = 10

    // Path segments carry only unreserved ASCII, so a `/` or `..` in an identifier cannot change the route.
    private static let pathSegmentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~"
    )

    private let accountId: String
    private let apiToken: String
    private let lock = NSLock()
    private var _databaseId: String
    private var session: URLSession?
    private var connectDeadline: PluginConnectDeadline?
    private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]
    private let queryTimeout = HttpQueryTimeoutBox()

    var databaseId: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _databaseId
        }
        set {
            lock.lock()
            _databaseId = newValue
            lock.unlock()
        }
    }

    init(accountId: String, apiToken: String, databaseId: String) {
        self.accountId = accountId
        self.apiToken = apiToken
        self._databaseId = databaseId
    }

    func setQueryTimeout(_ seconds: Int) {
        queryTimeout.set(serverTimeoutSeconds: seconds)
    }

    func createSession(
        configuration: URLSessionConfiguration = .default,
        connectDeadline: PluginConnectDeadline? = nil
    ) {
        // A copy, so the timeouts set here never reach a configuration the caller hands to its next session.
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        configuration.timeoutIntervalForRequest = max(
            HttpQueryTimeout.sessionBootstrapRequestTimeout,
            connectDeadline?.remainingSeconds() ?? 0
        )
        configuration.timeoutIntervalForResource = HttpQueryTimeout.sessionResourceTimeout

        lock.lock()
        self.connectDeadline = connectDeadline
        session = URLSession(configuration: configuration)
        lock.unlock()
    }

    func finishConnecting() {
        lock.withLock { connectDeadline = nil }
    }

    func invalidateSession() {
        lock.lock()
        session?.invalidateAndCancel()
        session = nil
        connectDeadline = nil
        lock.unlock()
    }

    func cancelAll() {
        let tasks = lock.withLock { Array(inFlight.values) }
        tasks.forEach { $0.cancel() }
    }

    var inFlightCount: Int {
        lock.withLock { inFlight.count }
    }

    fileprivate func register(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = task }
    }

    fileprivate func unregister(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = nil }
    }

    // MARK: - API Methods

    func executeRaw(sql: String, params: [Any?]? = nil) async throws -> D1RawResultPayload {
        let dbId = databaseId
        let url = try baseURL(databaseId: dbId, endpoint: "raw")
        let body = try buildQueryBody(sql: sql, params: params)
        let data = try await performRequest(url: url, method: "POST", body: body)

        let envelope = try JSONDecoder().decode(D1ApiResponse<[D1RawResultPayload]>.self, from: data)
        try checkApiSuccess(envelope)

        guard let results = envelope.result, let first = results.first else {
            throw D1HttpError(message: String(localized: "Empty response from Cloudflare D1"))
        }

        return first
    }

    func executeBatchRaw(statements: [(sql: String, params: [Any?]?)]) async throws -> [D1RawResultPayload] {
        let dbId = databaseId
        let batch = statements.map { stmt -> [String: Any] in
            var entry: [String: Any] = ["sql": stmt.sql]
            if let params = stmt.params {
                entry["params"] = params.map { $0 ?? NSNull() }
            }
            return entry
        }
        let body = try JSONSerialization.data(withJSONObject: ["batch": batch])

        let url = try baseURL(databaseId: dbId, endpoint: "raw")
        let data = try await performRequest(url: url, method: "POST", body: body)
        let envelope = try JSONDecoder().decode(D1ApiResponse<[D1RawResultPayload]>.self, from: data)
        try checkApiSuccess(envelope)
        return envelope.result ?? []
    }

    /// The path takes a database's UUID or its name, so one request resolves either form and returns both. A missing
    /// database is a ``D1HttpError`` with status 404.
    func getDatabaseDetails(nameOrId: String) async throws -> D1DatabaseInfo {
        let url = try baseURL(databaseId: nameOrId)
        let data = try await performRequest(url: url, method: "GET", body: nil)

        let envelope = try JSONDecoder().decode(D1ApiResponse<D1DatabaseInfo>.self, from: data)
        try checkApiSuccess(envelope)

        guard let result = envelope.result else {
            throw D1HttpError(message: String(localized: "Failed to fetch database details"))
        }

        return result
    }

    /// Every database in the account, page by page, up to ``databaseListPageLimit`` pages.
    func listDatabases() async throws -> [D1DatabaseInfo] {
        var databases: [D1DatabaseInfo] = []
        // A database created or dropped between two page reads shifts the pages, so one can repeat across them.
        var seen: Set<String> = []
        for page in 1...Self.databaseListPageLimit {
            let url = try baseURL(databaseId: nil, queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(Self.databasesPerPage)),
            ])
            let data = try await performRequest(url: url, method: "GET", body: nil)

            let response = try JSONDecoder().decode(D1ListResponse.self, from: data)
            guard response.success else {
                throw D1HttpError(message: String(localized: "Failed to list databases"))
            }

            databases += response.result.filter { seen.insert($0.uuid).inserted }
            if response.result.isEmpty { return databases }
            if let total = response.resultInfo?.totalCount {
                if databases.count >= total { return databases }
            } else if response.result.count < (response.resultInfo?.perPage ?? Self.databasesPerPage) {
                // The server may clamp per_page, so a short page is measured against the size it says it used.
                return databases
            }
        }
        Self.logger.warning("D1 database list stopped after \(Self.databaseListPageLimit) pages")
        return databases
    }

    func createDatabase(name: String) async throws -> D1DatabaseInfo {
        let url = try baseURL(databaseId: nil)
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let data = try await performRequest(url: url, method: "POST", body: body)

        let envelope = try JSONDecoder().decode(D1ApiResponse<D1DatabaseInfo>.self, from: data)
        try checkApiSuccess(envelope)

        guard let result = envelope.result else {
            throw D1HttpError(message: String(localized: "Failed to create database"))
        }

        return result
    }

    func deleteDatabase(databaseId: String) async throws {
        let url = try baseURL(databaseId: databaseId)
        let data = try await performRequest(url: url, method: "DELETE", body: nil)

        let envelope = try JSONDecoder().decode(D1ApiResponse<D1DatabaseInfo>.self, from: data)
        try checkApiSuccess(envelope)
    }

    // MARK: - Private Helpers

    private func baseURL(
        databaseId: String?,
        endpoint: String? = nil,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        guard let encodedAccount = accountId.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) else {
            throw D1HttpError(message: String(localized: "Invalid Account ID"))
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.cloudflare.com"
        var path = "/client/v4/accounts/\(encodedAccount)/d1/database"
        if let databaseId {
            guard let encodedDb = databaseId.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) else {
                throw D1HttpError(message: String(localized: "Invalid Account ID or database identifier"))
            }
            path += "/\(encodedDb)"
        }
        if let endpoint {
            path += "/\(endpoint)"
        }
        components.percentEncodedPath = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw D1HttpError(message: String(localized: "Invalid Account ID or database identifier"))
        }
        return url
    }

    private func buildQueryBody(sql: String, params: [Any?]?) throws -> Data {
        var dict: [String: Any] = ["sql": sql]
        if let params, !params.isEmpty {
            dict["params"] = params.map { $0 ?? NSNull() }
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    private func performRequest(url: URL, method: String, body: Data?) async throws -> Data {
        let connection = lock.withLock { (session: session, deadline: connectDeadline) }
        guard let session = connection.session else {
            throw D1HttpError(message: String(localized: "Not connected to database"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = connection.deadline?.remainingSeconds() ?? queryTimeout.requestTimeoutInterval
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let tracker = D1TaskTracker(client: self)
        defer { tracker.finish() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: tracker)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw D1HttpError(message: "Invalid response from server")
        }

        if !(200 ..< 300).contains(httpResponse.statusCode) {
            try handleHttpError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
        }

        return data
    }

    // Logs the status and Cloudflare's error code, never the body: an error body may echo what the request carried.
    private func handleHttpError(statusCode: Int, data: Data, response: HTTPURLResponse) throws {
        switch statusCode {
        case 401, 403:
            Self.logger.error("D1 auth error (\(statusCode))")
            throw D1HttpError(
                message: String(localized: "Authentication failed. Check your API token and Account ID."),
                statusCode: statusCode
            )
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            Self.logger.warning("D1 rate limited. Retry-After: \(retryAfter ?? "not specified")")
            if let seconds = retryAfter {
                throw D1HttpError(
                    message: String(format: String(localized: "Rate limited by Cloudflare. Retry after %@ seconds."), seconds),
                    statusCode: statusCode
                )
            } else {
                throw D1HttpError(
                    message: String(localized: "Rate limited by Cloudflare. Please try again later."),
                    statusCode: statusCode
                )
            }
        default:
            if let errorResponse = try? JSONDecoder().decode(
                D1ApiResponse<D1RawResultPayload>.self, from: data
            ), let errors = errorResponse.errors, let first = errors.first {
                Self.logger.error("D1 API error (\(statusCode)): code \(first.code ?? 0)")
                throw D1HttpError(message: first.message, statusCode: statusCode)
            }
            Self.logger.error("D1 HTTP error (\(statusCode))")
            let bodyText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw D1HttpError(message: bodyText.trimmingCharacters(in: .whitespacesAndNewlines), statusCode: statusCode)
        }
    }

    private func checkApiSuccess<T>(_ envelope: D1ApiResponse<T>) throws {
        guard envelope.success else {
            if let errors = envelope.errors, let first = errors.first {
                throw D1HttpError(message: first.message)
            }
            throw D1HttpError(message: String(localized: "API request failed"))
        }
    }
}

nonisolated private final class D1TaskTracker: PluginRedirectRefusingDelegate, @unchecked Sendable {
    private weak var client: D1HttpClient?
    private let lock = NSLock()
    private var task: URLSessionTask?

    init(client: D1HttpClient) {
        self.client = client
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
        client?.register(task)
    }

    func finish() {
        guard let task = lock.withLock({ task }) else { return }
        client?.unregister(task)
    }
}

// MARK: - Error

nonisolated struct D1HttpError: Error, LocalizedError {
    let message: String
    /// Set when the API answered, so a caller can tell a missing database (404) from every other failure.
    let statusCode: Int?

    init(message: String, statusCode: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
    }

    var errorDescription: String? { message }
}

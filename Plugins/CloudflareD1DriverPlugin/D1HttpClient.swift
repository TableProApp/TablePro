//
//  D1HttpClient.swift
//  TablePro
//

import Foundation
import os

// MARK: - API Response Types

struct D1ApiResponse<T: Decodable>: Decodable {
    let result: T?
    let success: Bool
    let errors: [D1ApiErrorDetail]?

    private enum CodingKeys: String, CodingKey {
        case result, success, errors
    }
}

struct D1ApiErrorDetail: Decodable {
    let code: Int?
    let message: String

    private enum CodingKeys: String, CodingKey {
        case code, message
    }
}

struct D1RawResultPayload: Decodable {
    let results: D1RawResults
    let meta: D1QueryMeta?
    let success: Bool

    private enum CodingKeys: String, CodingKey {
        case results, meta, success
    }
}

struct D1RawResults: Decodable {
    let columns: [String]?
    let rows: [[D1Value]]?

    private enum CodingKeys: String, CodingKey {
        case columns, rows
    }
}


struct D1QueryMeta: Decodable {
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

struct D1DatabaseInfo: Decodable {
    let uuid: String
    let name: String
    let createdAt: String?
    let version: String?

    private enum CodingKeys: String, CodingKey {
        case uuid, name, version
        case createdAt = "created_at"
    }
}

struct D1ListResponse: Decodable {
    let result: [D1DatabaseInfo]
    let success: Bool

    private enum CodingKeys: String, CodingKey {
        case result, success
    }
}

// No .bool case: D1/SQLite stores booleans as integers (0/1),
// and Foundation's JSONDecoder decodes JSON true/false as Int when Int is tried first.
enum D1Value: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case null

    var stringValue: String? {
        switch self {
        case .string(let val): return val
        case .int(let val): return String(val)
        case .double(let val): return String(val)
        case .null: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

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

        self = .null
    }
}

// MARK: - HTTP Client

final class D1HttpClient: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "D1HttpClient")

    private let accountId: String
    private let apiToken: String
    private let lock = NSLock()
    private var _databaseId: String
    private var session: URLSession?
    private var currentTask: URLSessionDataTask?

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

    func createSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300

        lock.lock()
        session = URLSession(configuration: config)
        lock.unlock()
    }

    func invalidateSession() {
        lock.lock()
        currentTask?.cancel()
        currentTask = nil
        session?.invalidateAndCancel()
        session = nil
        lock.unlock()
    }

    func cancelCurrentTask() {
        lock.lock()
        currentTask?.cancel()
        currentTask = nil
        lock.unlock()
    }

    // MARK: - API Methods

    func executeRaw(sql: String, params: [Any?]? = nil) async throws -> D1RawResultPayload {
        let dbId = databaseId
        let url = try baseURL(databaseId: dbId).appendingPathComponent("raw")
        let body = try buildQueryBody(sql: sql, params: params)
        let data = try await performRequest(url: url, method: "POST", body: body)

        let envelope = try JSONDecoder().decode(D1ApiResponse<[D1RawResultPayload]>.self, from: data)
        try checkApiSuccess(envelope)

        guard let results = envelope.result, let first = results.first else {
            throw D1HttpError(message: String(localized: "Empty response from Cloudflare D1"))
        }

        return first
    }

    func getDatabaseDetails() async throws -> D1DatabaseInfo {
        let dbId = databaseId
        let url = try baseURL(databaseId: dbId)
        let data = try await performRequest(url: url, method: "GET", body: nil)

        let envelope = try JSONDecoder().decode(D1ApiResponse<D1DatabaseInfo>.self, from: data)
        try checkApiSuccess(envelope)

        guard let result = envelope.result else {
            throw D1HttpError(message: String(localized: "Failed to fetch database details"))
        }

        return result
    }

    func listDatabases() async throws -> [D1DatabaseInfo] {
        let url = try baseURL(databaseId: nil)
        let data = try await performRequest(url: url, method: "GET", body: nil)

        let response = try JSONDecoder().decode(D1ListResponse.self, from: data)
        guard response.success else {
            throw D1HttpError(message: String(localized: "Failed to list databases"))
        }

        return response.result
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

    // MARK: - Private Helpers

    private func baseURL(databaseId: String?) throws -> URL {
        guard let encodedAccount = accountId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw D1HttpError(message: String(localized: "Invalid Account ID"))
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.cloudflare.com"
        var path = "/client/v4/accounts/\(encodedAccount)/d1/database"
        if let dbId = databaseId,
           let encodedDb = dbId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            path += "/\(encodedDb)"
        }
        components.path = path
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
        lock.lock()
        guard let session else {
            lock.unlock()
            throw D1HttpError(message: String(localized: "Not connected to database"))
        }
        lock.unlock()

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(
                            throwing: D1HttpError(message: "Empty response from server")
                        )
                        return
                    }
                    continuation.resume(returning: (data, response))
                }

                self.lock.lock()
                self.currentTask = task
                self.lock.unlock()

                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.currentTask?.cancel()
            self.currentTask = nil
            self.lock.unlock()
        }

        lock.lock()
        currentTask = nil
        lock.unlock()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw D1HttpError(message: "Invalid response from server")
        }

        if httpResponse.statusCode >= 400 {
            try handleHttpError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
        }

        return data
    }

    private func handleHttpError(statusCode: Int, data: Data, response: HTTPURLResponse) throws {
        let bodyText = String(data: data, encoding: .utf8) ?? "Unknown error"

        switch statusCode {
        case 401, 403:
            Self.logger.error("D1 auth error (\(statusCode)): \(bodyText)")
            throw D1HttpError(
                message: String(localized: "Authentication failed. Check your API token and Account ID.")
            )
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            Self.logger.warning("D1 rate limited. Retry-After: \(retryAfter ?? "not specified")")
            if let seconds = retryAfter {
                throw D1HttpError(
                    message: String(localized: "Rate limited by Cloudflare. Retry after \(seconds) seconds.")
                )
            } else {
                throw D1HttpError(
                    message: String(localized: "Rate limited by Cloudflare. Please try again later.")
                )
            }
        default:
            if let errorResponse = try? JSONDecoder().decode(
                D1ApiResponse<D1RawResultPayload>.self, from: data
            ), let errors = errorResponse.errors, let first = errors.first {
                Self.logger.error("D1 API error (\(statusCode)): \(first.message)")
                throw D1HttpError(message: first.message)
            }
            Self.logger.error("D1 HTTP error (\(statusCode)): \(bodyText)")
            throw D1HttpError(message: bodyText.trimmingCharacters(in: .whitespacesAndNewlines))
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

// MARK: - Error

struct D1HttpError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

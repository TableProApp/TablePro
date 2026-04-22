//
//  HranaHttpClient.swift
//  TablePro
//

import Foundation
import os

// MARK: - Hrana Protocol Types

enum HranaValue: Decodable {
    case null
    case integer(String)
    case float(Double)
    case text(String)
    case blob(Data)

    var stringValue: String? {
        switch self {
        case .null:
            return nil
        case .integer(let s):
            return s
        case .float(let d):
            if d.isFinite && d == d.rounded() && abs(d) <= 9_007_199_254_740_992 {
                return String(Int64(d))
            }
            return String(d)
        case .text(let s):
            return s
        case .blob(let data):
            return data.map { String(format: "%02x", $0) }.joined()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, value, base64
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "null":
            self = .null
        case "integer":
            let value = try container.decode(String.self, forKey: .value)
            self = .integer(value)
        case "float":
            let value = try container.decode(Double.self, forKey: .value)
            self = .float(value)
        case "text":
            let value = try container.decode(String.self, forKey: .value)
            self = .text(value)
        case "blob":
            let base64String = try container.decode(String.self, forKey: .base64)
            guard let data = Data(base64Encoded: base64String) else {
                self = .blob(Data())
                return
            }
            self = .blob(data)
        default:
            self = .null
        }
    }
}

struct HranaColumn: Decodable {
    let name: String
    let decltype: String?
}

struct HranaExecuteResult: Decodable {
    let cols: [HranaColumn]
    let rows: [[HranaValue]]
    let affectedRowCount: Int
    let lastInsertRowid: String?

    private enum CodingKeys: String, CodingKey {
        case cols, rows
        case affectedRowCount = "affected_row_count"
        case lastInsertRowid = "last_insert_rowid"
    }
}

struct HranaPipelineEnvelope: Decodable {
    let results: [HranaPipelineItem]
}

struct HranaPipelineItem: Decodable {
    let type: String
    let response: HranaResponseBody?
    let error: HranaErrorDetail?
}

struct HranaResponseBody: Decodable {
    let type: String
    let result: HranaExecuteResult?
}

struct HranaErrorDetail: Decodable {
    let message: String
    let code: String?
}

// MARK: - HTTP Client

final class HranaHttpClient: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "HranaHttpClient")

    private let baseUrl: URL
    private let authToken: String?
    private let lock = NSLock()
    private var session: URLSession?
    private var currentTask: URLSessionDataTask?

    init(baseUrl: URL, authToken: String?) {
        self.baseUrl = baseUrl
        self.authToken = authToken
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

    func execute(sql: String, args: [String?] = []) async throws -> HranaExecuteResult {
        let results = try await executeBatch(statements: [(sql: sql, args: args)])
        guard let first = results.first else {
            throw HranaHttpError(message: String(localized: "Empty response from server"))
        }
        return first
    }

    func executeBatch(statements: [(sql: String, args: [String?])]) async throws -> [HranaExecuteResult] {
        let requests: [[String: Any]] = statements.map { stmt in
            var stmtBody: [String: Any] = ["sql": stmt.sql]
            if !stmt.args.isEmpty {
                stmtBody["args"] = stmt.args.map { encodeArg($0) }
            }
            return ["type": "execute", "stmt": stmtBody]
        }

        let body = try JSONSerialization.data(withJSONObject: ["requests": requests])
        let url = baseUrl.appendingPathComponent("v2/pipeline")
        let data = try await performRequest(url: url, body: body)

        let envelope = try JSONDecoder().decode(HranaPipelineEnvelope.self, from: data)

        var results: [HranaExecuteResult] = []
        for item in envelope.results {
            if item.type == "error" {
                let message = item.error?.message ?? "Unknown error"
                throw HranaHttpError(message: message)
            }
            guard let response = item.response, let result = response.result else {
                throw HranaHttpError(message: String(localized: "Invalid response from server"))
            }
            results.append(result)
        }

        return results
    }

    // MARK: - Private Helpers

    private func encodeArg(_ value: String?) -> [String: Any] {
        guard let value else {
            return ["type": "null"]
        }
        if Int64(value) != nil {
            return ["type": "integer", "value": value]
        }
        if let d = Double(value), Int64(value) == nil {
            return ["type": "float", "value": d]
        }
        return ["type": "text", "value": value]
    }

    private func performRequest(url: URL, body: Data) async throws -> Data {
        lock.lock()
        guard let session else {
            lock.unlock()
            throw HranaHttpError(message: String(localized: "Not connected to database"))
        }
        lock.unlock()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
                            throwing: HranaHttpError(message: "Empty response from server")
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
            throw HranaHttpError(message: "Invalid response from server")
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
            Self.logger.error("Hrana auth error (\(statusCode)): \(bodyText)")
            throw HranaHttpError(
                message: String(localized: "Authentication failed. Check your auth token.")
            )
        case 404:
            Self.logger.error("Hrana server not found (\(statusCode)): \(bodyText)")
            throw HranaHttpError(
                message: String(localized: "Server not found. Check your database URL.")
            )
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            Self.logger.warning("Hrana rate limited. Retry-After: \(retryAfter ?? "not specified")")
            if let seconds = retryAfter {
                throw HranaHttpError(
                    message: String(format: String(localized: "Rate limited. Retry after %@ seconds."), seconds)
                )
            } else {
                throw HranaHttpError(
                    message: String(localized: "Rate limited. Please try again later.")
                )
            }
        default:
            if let errorEnvelope = try? JSONDecoder().decode(HranaPipelineEnvelope.self, from: data) {
                for item in errorEnvelope.results where item.type == "error" {
                    if let errorDetail = item.error {
                        Self.logger.error("Hrana API error (\(statusCode)): \(errorDetail.message)")
                        throw HranaHttpError(message: errorDetail.message)
                    }
                }
            }
            Self.logger.error("Hrana HTTP error (\(statusCode)): \(bodyText)")
            throw HranaHttpError(message: bodyText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func normalizeUrl(_ urlString: String) -> String {
        var normalized = urlString
        if normalized.hasPrefix("libsql://") {
            normalized = "https://" + normalized.dropFirst("libsql://".count)
        }
        while normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        return normalized
    }
}

// MARK: - Error

struct HranaHttpError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

//
//  ElasticsearchConnection.swift
//  ElasticsearchDriverPlugin
//
//  HTTP client for the Elasticsearch REST API.
//

import Foundation
import os
import TableProPluginKit

internal enum ElasticsearchError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case serverError(String)
    case authFailed(String)
    case requestCancelled
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to Elasticsearch")
        case .connectionFailed(let detail):
            return String(format: String(localized: "Connection failed: %@"), detail)
        case .serverError(let detail):
            return String(format: String(localized: "Elasticsearch error: %@"), detail)
        case .authFailed(let detail):
            return String(format: String(localized: "Authentication failed: %@"), detail)
        case .requestCancelled:
            return String(localized: "Request was cancelled")
        case .invalidResponse(let detail):
            return String(format: String(localized: "Invalid response: %@"), detail)
        }
    }
}

internal struct ElasticsearchResponse {
    let statusCode: Int
    let json: Any?
    let rawText: String
}

internal struct ElasticsearchIndexInfo {
    let name: String
    let docsCount: Int?
    let storeSize: String?
}

internal final class ElasticsearchConnection: NSObject, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var _session: URLSession?
    private var _currentTask: URLSessionDataTask?
    private var _serverVersion: String?
    private let queryTimeout = HttpQueryTimeoutBox()

    private let baseURL: URL
    private let authHeader: String?
    private let skipTLSVerify: Bool

    private static let logger = Logger(subsystem: "com.TablePro", category: "ElasticsearchConnection")

    var serverVersion: String? { lock.withLock { _serverVersion } }

    init(config: DriverConnectionConfig) throws {
        self.config = config

        let scheme = config.ssl.isEnabled ? "https" : "http"
        let host = config.host.isEmpty ? "localhost" : config.host
        let port = config.port > 0 ? config.port : 9200
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else {
            throw ElasticsearchError.connectionFailed("Invalid host: \(host):\(port)")
        }
        self.baseURL = url
        self.authHeader = Self.resolveAuthHeader(config: config)
        self.skipTLSVerify = (config.additionalFields["esSkipTLSVerify"] == "true")
            || (config.ssl.isEnabled && !config.ssl.verifiesCertificate)
    }

    func setQueryTimeout(_ seconds: Int) {
        queryTimeout.set(serverTimeoutSeconds: seconds)
    }

    // MARK: - Lifecycle

    func connect() async throws {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = HttpQueryTimeout.sessionBootstrapRequestTimeout
        sessionConfig.timeoutIntervalForResource = HttpQueryTimeout.sessionResourceTimeout
        let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
        lock.withLock { _session = session }

        let info = try await request(method: "GET", path: "/")
        guard info.statusCode == 200 else {
            throw mapError(info, fallback: "Connection check failed")
        }
        if let json = info.json as? [String: Any],
           let version = json["version"] as? [String: Any],
           let number = version["number"] as? String {
            lock.withLock { _serverVersion = number }
        }
    }

    func disconnect() {
        lock.withLock {
            _currentTask?.cancel()
            _currentTask = nil
            _session?.finishTasksAndInvalidate()
            _session = nil
        }
    }

    func ping() async throws {
        let response = try await request(method: "GET", path: "/_cluster/health")
        guard response.statusCode == 200 else {
            throw mapError(response, fallback: "Ping failed")
        }
    }

    func cancelCurrentRequest() {
        lock.withLock {
            _currentTask?.cancel()
            _currentTask = nil
        }
    }

    // MARK: - API Operations

    func catIndices() async throws -> [ElasticsearchIndexInfo] {
        let response = try await request(
            method: "GET",
            path: "/_cat/indices?format=json&h=index,docs.count,store.size&s=index"
        )
        guard response.statusCode == 200 else { throw mapError(response, fallback: "Failed to list indices") }
        guard let rows = response.json as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let name = row["index"] as? String else { return nil }
            let docs = (row["docs.count"] as? String).flatMap { Int($0) }
            return ElasticsearchIndexInfo(name: name, docsCount: docs, storeSize: row["store.size"] as? String)
        }
    }

    func mappingProperties(index: String) async throws -> [ElasticsearchColumn] {
        let response = try await request(method: "GET", path: "/\(encode(index))/_mapping")
        guard response.statusCode == 200 else { throw mapError(response, fallback: "Failed to fetch mapping") }
        guard let json = response.json as? [String: Any] else {
            Self.logger.error("mappingProperties \(index, privacy: .public): response.json not a dictionary; raw=\(response.rawText.prefix(300), privacy: .public)")
            return []
        }
        let properties = ElasticsearchMappingFlattener.properties(fromMappingResponse: json, index: index)
        let columns = ElasticsearchMappingFlattener.flattenMapping(properties: properties)
        Self.logger.debug("""
        mappingProperties \(index, privacy: .public): topKeys=[\(json.keys.joined(separator: ","), privacy: .public)] \
        propertyCount=\(properties.count) columnCount=\(columns.count) \
        columns=[\(columns.map { "\($0.name):\($0.type)\($0.hasKeywordSubfield ? "+kw" : "")" }.joined(separator: ","), privacy: .public)]
        """)
        return columns
    }

    func mappingJSON(index: String) async throws -> String {
        let response = try await request(method: "GET", path: "/\(encode(index))/_mapping")
        guard response.statusCode == 200 else { throw mapError(response, fallback: "Failed to fetch mapping") }
        return response.rawText
    }

    func count(index: String, query: [String: Any]?) async throws -> Int {
        let body: String?
        if let query, JSONSerialization.isValidJSONObject(["query": query]) {
            body = String(data: try JSONSerialization.data(withJSONObject: ["query": query]), encoding: .utf8)
        } else {
            body = nil
        }
        let response = try await request(method: "POST", path: "/\(encode(index))/_count", body: body)
        guard response.statusCode == 200, let json = response.json as? [String: Any] else {
            throw mapError(response, fallback: "Count failed")
        }
        return (json["count"] as? Int) ?? 0
    }

    func search(index: String?, body: [String: Any]) async throws -> ElasticsearchResponse {
        let path = index.map { "/\(encode($0))/_search" } ?? "/_search"
        let bodyString = try serialize(body)
        let response = try await request(method: "POST", path: path, body: bodyString)
        guard response.statusCode == 200 else { throw mapError(response, fallback: "Search failed") }
        return response
    }

    func openPointInTime(index: String, keepAlive: String) async throws -> String {
        let response = try await request(method: "POST", path: "/\(encode(index))/_pit?keep_alive=\(keepAlive)")
        guard response.statusCode == 200,
              let json = response.json as? [String: Any],
              let id = json["id"] as? String
        else { throw mapError(response, fallback: "Failed to open point-in-time") }
        return id
    }

    func closePointInTime(id: String) async {
        let body = try? serialize(["id": id])
        _ = try? await request(method: "DELETE", path: "/_pit", body: body)
    }

    // MARK: - Raw Request

    @discardableResult
    func request(method: String, path: String, body: String? = nil) async throws -> ElasticsearchResponse {
        let session: URLSession = try lock.withLock {
            guard let session = _session else { throw ElasticsearchError.notConnected }
            return session
        }

        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ElasticsearchError.connectionFailed("Invalid path: \(path)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = Self.effectiveMethod(method, hasBody: body != nil)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authHeader {
            urlRequest.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        if let body {
            urlRequest.httpBody = Data(body.utf8)
        }
        urlRequest.timeoutInterval = queryTimeout.requestTimeoutInterval

        let (data, response) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
                self?.lock.withLock { self?._currentTask = nil }
                if let error {
                    if (error as? URLError)?.code == .cancelled {
                        continuation.resume(throwing: ElasticsearchError.requestCancelled)
                    } else {
                        continuation.resume(throwing: ElasticsearchError.connectionFailed(error.localizedDescription))
                    }
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: ElasticsearchError.invalidResponse("Empty response"))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            self.lock.withLock { self._currentTask = task }
            task.resume()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElasticsearchError.invalidResponse("Not an HTTP response")
        }

        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let rawText = String(data: data, encoding: .utf8) ?? ""
        return ElasticsearchResponse(statusCode: httpResponse.statusCode, json: json, rawText: rawText)
    }

    // MARK: - Helpers

    private func serialize(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ElasticsearchError.invalidResponse("Invalid request body")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    private func mapError(_ response: ElasticsearchResponse, fallback: String) -> ElasticsearchError {
        if response.statusCode == 401 || response.statusCode == 403 {
            return .authFailed(reason(from: response) ?? fallback)
        }
        return .serverError(reason(from: response) ?? "HTTP \(response.statusCode): \(fallback)")
    }

    private func reason(from response: ElasticsearchResponse) -> String? {
        guard let json = response.json as? [String: Any] else {
            return response.rawText.isEmpty ? nil : response.rawText
        }
        if let error = json["error"] as? [String: Any] {
            let type = error["type"] as? String
            let reason = error["reason"] as? String
            return [type, reason].compactMap { $0 }.joined(separator: ": ")
        }
        if let error = json["error"] as? String {
            return error
        }
        return nil
    }

    static func effectiveMethod(_ method: String, hasBody: Bool) -> String {
        guard hasBody else { return method }
        let upper = method.uppercased()
        return (upper == "GET" || upper == "HEAD") ? "POST" : method
    }

    private static func resolveAuthHeader(config: DriverConnectionConfig) -> String? {
        switch config.additionalFields["esAuthMethod"] {
        case "apiKey":
            let key = config.additionalFields["esApiKey"] ?? ""
            return key.isEmpty ? nil : "ApiKey \(key)"
        case "none":
            return nil
        default:
            guard !config.username.isEmpty else { return nil }
            let credentials = "\(config.username):\(config.password)"
            return "Basic \(Data(credentials.utf8).base64EncodedString())"
        }
    }
}

extension ElasticsearchConnection: URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard skipTLSVerify,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

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

    private let nodes: [ElasticsearchNode]
    private var _activeNode = 0
    private var _cancelGeneration = 0
    private let authHeader: String?
    private let skipTLSVerify: Bool
    private let connectTimeoutMilliseconds: Int

    private static let logger = Logger(subsystem: "com.TablePro", category: "ElasticsearchConnection")

    var serverVersion: String? { lock.withLock { _serverVersion } }

    init(config: DriverConnectionConfig) throws {
        self.config = config

        self.nodes = ElasticsearchNodes.nodes(config: config)
        guard !nodes.isEmpty else {
            let hosts = config.additionalFields[ElasticsearchNodes.hostsField] ?? "\(config.host):\(config.port)"
            throw ElasticsearchError.connectionFailed("Invalid host: \(hosts)")
        }
        self.authHeader = Self.resolveAuthHeader(config: config)
        self.skipTLSVerify = (config.additionalFields["esSkipTLSVerify"] == "true")
            || (config.ssl.isEnabled && !config.ssl.verifiesCertificate)
        self.connectTimeoutMilliseconds = PluginConnectTimeout.milliseconds(
            in: config.additionalFields,
            default: Int(HttpQueryTimeout.sessionBootstrapRequestTimeout * 1_000)
        )
    }

    func setQueryTimeout(_ seconds: Int) {
        queryTimeout.set(serverTimeoutSeconds: seconds)
    }

    // MARK: - Lifecycle

    func connect() async throws {
        let deadline = PluginConnectDeadline(milliseconds: connectTimeoutMilliseconds)
        let connectTimeout = TimeInterval(connectTimeoutMilliseconds) / 1_000
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = connectTimeout
        sessionConfig.timeoutIntervalForResource = HttpQueryTimeout.sessionResourceTimeout
        let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
        lock.withLock { _session = session }

        do {
            try await connectToFirstAvailableNode(through: session, deadline: deadline)
        } catch {
            disconnect()
            throw error
        }
    }

    /// Each node gets an equal share of what is left of the deadline, so a node that never
    /// answers cannot spend the time the others need.
    private func connectToFirstAvailableNode(
        through session: URLSession,
        deadline: PluginConnectDeadline
    ) async throws {
        var failures: [String] = []
        for (index, node) in nodes.enumerated() {
            if Task.isCancelled { throw ElasticsearchError.requestCancelled }
            let share = deadline.remainingSeconds() / Double(nodes.count - index)
            let taskBox = PluginURLSessionTaskBox()
            // URLSession's timeout restarts whenever bytes arrive, so a node that trickles its reply
            // would otherwise hold the connect past its share.
            DispatchQueue.global().asyncAfter(deadline: .now() + share) { taskBox.cancel() }
            let info: ElasticsearchResponse
            do {
                info = try await send(
                    method: "GET",
                    path: "/",
                    body: nil,
                    to: node,
                    through: session,
                    timeoutInterval: share,
                    taskBox: taskBox
                )
            } catch let error as URLError {
                failures.append("\(node.name): \(error.localizedDescription)")
                continue
            } catch ElasticsearchError.requestCancelled where !Task.isCancelled {
                failures.append("\(node.name): \(URLError(.timedOut).localizedDescription)")
                continue
            }
            if ElasticsearchFailover.nodeUnavailable(statusCode: info.statusCode) {
                let reason = mapError(info, fallback: "Connection check failed").localizedDescription
                failures.append("\(node.name): \(reason)")
                continue
            }
            guard info.statusCode == 200 else {
                throw mapError(info, fallback: "Connection check failed")
            }
            let number = ((info.json as? [String: Any])?["version"] as? [String: Any])?["number"] as? String
            lock.withLock {
                _activeNode = index
                if let number { _serverVersion = number }
            }
            return
        }
        throw ElasticsearchError.connectionFailed(failures.joined(separator: "; "))
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
            _cancelGeneration &+= 1
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
            Self.logger.error("mappingProperties \(index, privacy: .private(mask: .hash)): response.json not a dictionary; raw=\(response.rawText.prefix(300), privacy: .private)")
            return []
        }
        let properties = ElasticsearchMappingFlattener.properties(fromMappingResponse: json, index: index)
        let columns = ElasticsearchMappingFlattener.flattenMapping(properties: properties)
        Self.logger.debug("""
        mappingProperties \(index, privacy: .private(mask: .hash)): topKeys=[\(json.keys.joined(separator: ","), privacy: .private)] \
        propertyCount=\(properties.count) columnCount=\(columns.count) \
        columns=[\(columns.map { "\($0.name):\($0.type)\($0.hasKeywordSubfield ? "+kw" : "")" }.joined(separator: ","), privacy: .private)]
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
        let response = try await request(
            method: "POST",
            path: "/\(encode(index))/_count",
            body: body,
            isRead: true
        )
        guard response.statusCode == 200, let json = response.json as? [String: Any] else {
            throw mapError(response, fallback: "Count failed")
        }
        return (json["count"] as? Int) ?? 0
    }

    func search(index: String?, body: [String: Any]) async throws -> ElasticsearchResponse {
        let path = index.map { "/\(encode($0))/_search" } ?? "/_search"
        let bodyString = try serialize(body)
        let response = try await request(method: "POST", path: path, body: bodyString, isRead: true)
        guard response.statusCode == 200 else { throw mapError(response, fallback: "Search failed") }
        return response
    }

    func openPointInTime(index: String, keepAlive: String) async throws -> String {
        let response = try await request(
            method: "POST",
            path: "/\(encode(index))/_pit?keep_alive=\(keepAlive)",
            isRead: true
        )
        guard response.statusCode == 200,
              let json = response.json as? [String: Any],
              let id = json["id"] as? String
        else { throw mapError(response, fallback: "Failed to open point-in-time") }
        return id
    }

    func closePointInTime(id: String) async {
        let body = try? serialize(["id": id])
        _ = try? await request(method: "DELETE", path: "/_pit", body: body, isRead: true)
    }

    // MARK: - Raw Request

    /// Sent to the node that answered last, and on a failure to the next node when
    /// `ElasticsearchFailover` allows it. Each node is tried at most once, and the node that
    /// answers becomes the one later requests use.
    @discardableResult
    func request(
        method: String,
        path: String,
        body: String? = nil,
        isRead: Bool? = nil
    ) async throws -> ElasticsearchResponse {
        let session: URLSession = try lock.withLock {
            guard let session = _session else { throw ElasticsearchError.notConnected }
            return session
        }
        let isRead = isRead ?? ElasticsearchFailover.isRead(method: Self.effectiveMethod(method, hasBody: body != nil))
        let (start, generation) = lock.withLock { (_activeNode, _cancelGeneration) }

        for attempt in 0 ..< nodes.count {
            let index = (start + attempt) % nodes.count
            let isLastAttempt = attempt == nodes.count - 1
            do {
                let response = try await send(
                    method: method,
                    path: path,
                    body: body,
                    to: nodes[index],
                    through: session,
                    timeoutInterval: queryTimeout.requestTimeoutInterval,
                    taskBox: nil
                )
                if isLastAttempt || !isRead
                    || !ElasticsearchFailover.nodeUnavailable(statusCode: response.statusCode) {
                    lock.withLock { _activeNode = index }
                    return response
                }
                Self.logger.notice("Elasticsearch node answered HTTP \(response.statusCode), trying the next node")
            } catch let error as URLError {
                guard !isLastAttempt,
                      ElasticsearchFailover.resends(after: error.code, isRead: isRead)
                else {
                    if error.code == .timedOut {
                        lock.withLock { if _activeNode == start { _activeNode = (index + 1) % nodes.count } }
                    }
                    throw ElasticsearchError.connectionFailed(error.localizedDescription)
                }
                Self.logger.notice("Elasticsearch node unreachable (\(error.code.rawValue)), trying the next node")
            }
            let stopped = lock.withLock { _cancelGeneration != generation }
            if stopped || Task.isCancelled { throw ElasticsearchError.requestCancelled }
        }
        throw ElasticsearchError.notConnected
    }

    /// Throws `URLError` for a transport failure, so the caller can tell whether the request may
    /// have reached the node.
    private func send(
        method: String,
        path: String,
        body: String?,
        to node: ElasticsearchNode,
        through session: URLSession,
        timeoutInterval: TimeInterval,
        taskBox: PluginURLSessionTaskBox?
    ) async throws -> ElasticsearchResponse {
        // A console path such as `//other.example/x` resolves to another host, which would get the
        // Authorization header.
        guard let url = URL(string: path, relativeTo: node.baseURL),
              url.host == node.baseURL.host, url.port == node.baseURL.port
        else {
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
        urlRequest.timeoutInterval = timeoutInterval

        let dataAndResponse: (Data, URLResponse)
        if let taskBox {
            dataAndResponse = try await withTaskCancellationHandler {
                try await perform(urlRequest, through: session, taskBox: taskBox)
            } onCancel: {
                taskBox.cancel()
            }
        } else {
            dataAndResponse = try await perform(urlRequest, through: session, taskBox: nil)
        }
        let (data, response) = dataAndResponse

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElasticsearchError.invalidResponse("Not an HTTP response")
        }

        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let rawText = String(data: data, encoding: .utf8) ?? ""
        return ElasticsearchResponse(statusCode: httpResponse.statusCode, json: json, rawText: rawText)
    }

    private func perform(
        _ request: URLRequest,
        through session: URLSession,
        taskBox: PluginURLSessionTaskBox?
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                taskBox?.finish()
                self?.lock.withLock { self?._currentTask = nil }
                if let error {
                    if let urlError = error as? URLError {
                        continuation.resume(
                            throwing: urlError.code == .cancelled ? ElasticsearchError.requestCancelled : urlError
                        )
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
            taskBox?.set(task)
            task.resume()
        }
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

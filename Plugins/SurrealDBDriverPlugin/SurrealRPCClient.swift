//
//  SurrealRPCClient.swift
//  SurrealDBDriverPlugin
//

import Foundation
import os

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    func set(_ task: URLSessionTask) {
        lock.withLock { self.task = task }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }
}

public struct SurrealStatementResult: Sendable {
    public let status: String
    public let value: SurrealValue
    public let executionTime: TimeInterval

    public var isFailure: Bool {
        status.uppercased() == "ERR"
    }
}

public final class SurrealRPCClient: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SurrealDBDriver")

    private let config: SurrealDBConnectionConfig
    private let lock = NSLock()
    private var session: URLSession?
    private var bearerToken: String?
    private var inFlight: [URLSessionTask] = []
    private var requestId: Int = 0
    private var timeoutSeconds: Int?

    public private(set) var serverVersion: String?

    public init(config: SurrealDBConnectionConfig) {
        self.config = config
        super.init()
    }

    public func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]
        configuration.timeoutIntervalForRequest = 60
        let delegate = config.skipTLSVerify ? self : nil
        lock.withLock {
            session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    public func stop() {
        lock.withLock {
            session?.invalidateAndCancel()
            session = nil
            inFlight.removeAll()
            bearerToken = nil
        }
    }

    public func cancelInFlight() {
        let tasks = lock.withLock {
            let snapshot = inFlight
            inFlight.removeAll()
            return snapshot
        }
        tasks.forEach { $0.cancel() }
    }

    public func applyTimeout(_ seconds: Int) {
        lock.withLock { timeoutSeconds = seconds > 0 ? seconds : nil }
    }

    // MARK: - Authentication

    public func authenticate() async throws {
        switch config.authLevel {
        case .token:
            lock.withLock { bearerToken = config.token.trimmingCharacters(in: .whitespaces) }
        case .record:
            lock.withLock { bearerToken = nil }
            let token = try await signin()
            lock.withLock { bearerToken = token }
        case .root, .namespace, .database:
            lock.withLock { bearerToken = nil }
        }
    }

    private func signin() async throws -> String {
        var payload: [String: String] = ["user": config.username, "pass": config.password]
        payload["ns"] = config.namespace
        payload["db"] = config.database
        payload["ac"] = config.access

        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = try makeRequest(path: "/signin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SurrealDBError.authenticationFailed(Self.plainText(data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String else {
            throw SurrealDBError.authenticationFailed(String(localized: "SurrealDB did not return a token."))
        }
        return token
    }

    // MARK: - Queries

    @discardableResult
    public func query(
        _ statement: String,
        variables: [(key: String, value: SurrealValue)] = [],
        namespace: String?,
        database: String?
    ) async throws -> [SurrealStatementResult] {
        var params: [SurrealValue] = [.string(statement)]
        if !variables.isEmpty {
            params.append(.object(variables))
        }

        let id = lock.withLock { () -> Int in
            requestId += 1
            return requestId
        }

        let envelope = SurrealValue.object([
            (key: "id", value: .int(Int64(id))),
            (key: "method", value: .string("query")),
            (key: "params", value: .array(params))
        ])

        var request = try makeRequest(path: "/rpc")
        request.setValue("application/cbor", forHTTPHeaderField: "Content-Type")
        request.setValue("application/cbor", forHTTPHeaderField: "Accept")
        applyScopeHeaders(&request, namespace: namespace, database: database)
        request.httpBody = SurrealCBOR.encode(envelope)

        let (data, response) = try await send(request)
        return try decode(data: data, response: response)
    }

    public func probeVersion() async throws {
        var request = try makeRequest(path: "/version", authenticated: false)
        request.httpMethod = "GET"
        let (data, response) = try await send(request)

        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "surreal-version")
        let raw = header ?? Self.plainText(data)
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { serverVersion = version }

        guard SurrealServerVersion.isSupported(version) else {
            throw SurrealDBError.unsupportedServerVersion(version)
        }
    }

    // MARK: - Request plumbing

    private func makeRequest(path: String, authenticated: Bool = true) throws -> URLRequest {
        guard let base = config.baseURL, let url = URL(string: path, relativeTo: base) else {
            throw SurrealDBError.invalidEndpoint(config.host)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeout = lock.withLock({ timeoutSeconds }) {
            request.timeoutInterval = TimeInterval(timeout)
        }
        guard authenticated else { return request }

        let token = lock.withLock { bearerToken }
        if let token, !token.isEmpty {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            return request
        }
        if config.authLevel.usesCredentials, !config.username.isEmpty {
            let raw = config.username + ":" + config.password
            let encoded = Data(raw.utf8).base64EncodedString()
            request.setValue("Basic " + encoded, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func applyScopeHeaders(_ request: inout URLRequest, namespace: String?, database: String?) {
        if let namespace, !namespace.isEmpty {
            request.setValue(namespace, forHTTPHeaderField: "surreal-ns")
        }
        if let database, !database.isEmpty {
            request.setValue(database, forHTTPHeaderField: "surreal-db")
        }
        switch config.authLevel {
        case .namespace:
            request.setValue(config.namespace, forHTTPHeaderField: "surreal-auth-ns")
        case .database, .record:
            request.setValue(config.namespace, forHTTPHeaderField: "surreal-auth-ns")
            request.setValue(config.database, forHTTPHeaderField: "surreal-auth-db")
        case .root, .token:
            break
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    guard let session else {
                        continuation.resume(throwing: SurrealDBError.notConnected)
                        return
                    }
                    let task = session.dataTask(with: request) { [weak self] data, response, error in
                        self?.finish()
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let data, let response else {
                            continuation.resume(throwing: SurrealDBError.decodingFailed(String(localized: "Empty response")))
                            return
                        }
                        continuation.resume(returning: (data, response))
                    }
                    inFlight.append(task)
                    box.set(task)
                    task.resume()
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    private func finish() {
        lock.withLock {
            inFlight.removeAll { $0.state == .completed || $0.state == .canceling }
        }
    }

    // MARK: - Decoding

    private func decode(data: Data, response: URLResponse) throws -> [SurrealStatementResult] {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 {
            throw SurrealDBError.authenticationFailed(Self.plainText(data))
        }

        guard let envelope = try? SurrealCBOR.decode(data) else {
            guard (200..<300).contains(status) else {
                throw SurrealDBError.requestFailed(status: status, message: Self.plainText(data))
            }
            throw SurrealDBError.decodingFailed(Self.plainText(data))
        }

        if let error = envelope["error"] {
            let message = error["message"]?.stringValue ?? String(localized: "SurrealDB rejected the request.")
            throw SurrealDBError.queryFailed(message: message, kind: error["kind"]?.stringValue)
        }

        guard (200..<300).contains(status) else {
            throw SurrealDBError.requestFailed(status: status, message: Self.plainText(data))
        }

        guard let results = envelope["result"]?.arrayValues else {
            return [SurrealStatementResult(status: "OK", value: envelope["result"] ?? .none, executionTime: 0)]
        }

        return results.map { entry in
            SurrealStatementResult(
                status: entry["status"]?.stringValue ?? "OK",
                value: entry["result"] ?? .none,
                executionTime: Self.duration(entry["time"]?.stringValue)
            )
        }
    }

    public static func firstFailure(_ results: [SurrealStatementResult]) -> SurrealDBError? {
        guard let failure = results.first(where: { $0.isFailure }) else { return nil }
        let message = failure.value.stringValue ?? String(localized: "The SurrealDB statement failed.")
        return SurrealDBError.queryFailed(message: message, kind: nil)
    }

    private static func plainText(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return String(localized: "SurrealDB returned no details.") }
        return text
    }

    private static func duration(_ raw: String?) -> TimeInterval {
        guard let raw else { return 0 }
        let units: [(String, Double)] = [("ns", 1e-9), ("µs", 1e-6), ("us", 1e-6), ("ms", 1e-3), ("s", 1)]
        for (suffix, scale) in units where raw.hasSuffix(suffix) {
            let number = raw.dropLast(suffix.count)
            guard let value = Double(number) else { return 0 }
            return value * scale
        }
        return 0
    }
}

extension SurrealRPCClient: URLSessionDelegate {
    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard config.skipTLSVerify,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

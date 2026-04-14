//
//  EtcdHttpClient.swift
//  TablePro
//

import Foundation
import os
import Security
import TableProPluginKit

// MARK: - Error Types

internal enum EtcdError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case serverError(String)
    case authFailed(String)
    case requestCancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to etcd")
        case .connectionFailed(let detail):
            return String(localized: "Connection failed: \(detail)")
        case .serverError(let detail):
            return String(localized: "Server error: \(detail)")
        case .authFailed(let detail):
            return String(localized: "Authentication failed: \(detail)")
        case .requestCancelled:
            return String(localized: "Request was cancelled")
        }
    }
}

// MARK: - Codable Types

internal struct EtcdResponseHeader: Decodable {
    let clusterId: String?
    let memberId: String?
    let revision: String?
    let raftTerm: String?

    private enum CodingKeys: String, CodingKey {
        case clusterId = "cluster_id"
        case memberId = "member_id"
        case revision
        case raftTerm = "raft_term"
    }
}

internal struct EtcdKeyValue: Decodable {
    let key: String
    let value: String?
    let version: String?
    let createRevision: String?
    let modRevision: String?
    let lease: String?

    private enum CodingKeys: String, CodingKey {
        case key
        case value
        case version
        case createRevision = "create_revision"
        case modRevision = "mod_revision"
        case lease
    }
}

// KV Request/Response

internal struct EtcdRangeRequest: Encodable {
    let key: String
    var rangeEnd: String?
    var limit: Int64?
    var sortOrder: String?
    var sortTarget: String?
    var keysOnly: Bool?
    var countOnly: Bool?

    private enum CodingKeys: String, CodingKey {
        case key
        case rangeEnd = "range_end"
        case limit
        case sortOrder = "sort_order"
        case sortTarget = "sort_target"
        case keysOnly = "keys_only"
        case countOnly = "count_only"
    }
}

internal struct EtcdRangeResponse: Decodable {
    let kvs: [EtcdKeyValue]?
    let count: String?
    let more: Bool?
}

internal struct EtcdPutRequest: Encodable {
    let key: String
    let value: String
    var lease: String?
    var prevKv: Bool?

    private enum CodingKeys: String, CodingKey {
        case key
        case value
        case lease
        case prevKv = "prev_kv"
    }
}

internal struct EtcdPutResponse: Decodable {
    let header: EtcdResponseHeader?
    let prevKv: EtcdKeyValue?

    private enum CodingKeys: String, CodingKey {
        case header
        case prevKv = "prev_kv"
    }
}

internal struct EtcdDeleteRequest: Encodable {
    let key: String
    var rangeEnd: String?
    var prevKv: Bool?

    private enum CodingKeys: String, CodingKey {
        case key
        case rangeEnd = "range_end"
        case prevKv = "prev_kv"
    }
}

internal struct EtcdDeleteResponse: Decodable {
    let deleted: String?
    let prevKvs: [EtcdKeyValue]?

    private enum CodingKeys: String, CodingKey {
        case deleted
        case prevKvs = "prev_kvs"
    }
}

// Lease

internal struct EtcdLeaseGrantRequest: Encodable {
    let TTL: String
    var ID: String?
}

internal struct EtcdLeaseGrantResponse: Decodable {
    let ID: String?
    let TTL: String?
    let error: String?
}

internal struct EtcdLeaseRevokeRequest: Encodable {
    let ID: String
}

internal struct EtcdLeaseTimeToLiveRequest: Encodable {
    let ID: String
    let keys: Bool?
}

internal struct EtcdLeaseTimeToLiveResponse: Decodable {
    let ID: String?
    let TTL: String?
    let grantedTTL: String?
    let keys: [String]?
}

internal struct EtcdLeaseListResponse: Decodable {
    let leases: [EtcdLeaseStatus]?
}

internal struct EtcdLeaseStatus: Decodable {
    let ID: String
}

// Cluster

internal struct EtcdMemberListResponse: Decodable {
    let members: [EtcdMember]?
    let header: EtcdResponseHeader?
}

internal struct EtcdMember: Decodable {
    let ID: String?
    let name: String?
    let peerURLs: [String]?
    let clientURLs: [String]?
    let isLearner: Bool?
}

internal struct EtcdStatusResponse: Decodable {
    let version: String?
    let dbSize: String?
    let leader: String?
    let raftIndex: String?
    let raftTerm: String?
    let errors: [String]?
}

// Watch

internal struct EtcdWatchRequest: Encodable {
    let createRequest: EtcdWatchCreateRequest

    private enum CodingKeys: String, CodingKey {
        case createRequest = "create_request"
    }
}

internal struct EtcdWatchCreateRequest: Encodable {
    let key: String
    var rangeEnd: String?

    private enum CodingKeys: String, CodingKey {
        case key
        case rangeEnd = "range_end"
    }
}

internal struct EtcdWatchStreamResponse: Decodable {
    let result: EtcdWatchResult?
}

internal struct EtcdWatchResult: Decodable {
    let events: [EtcdWatchEvent]?
    let header: EtcdResponseHeader?
}

internal struct EtcdWatchEvent: Decodable {
    let type: String?
    let kv: EtcdKeyValue?
    let prevKv: EtcdKeyValue?

    private enum CodingKeys: String, CodingKey {
        case type
        case kv
        case prevKv = "prev_kv"
    }
}

// Auth

internal struct EtcdAuthRequest: Encodable {
    let name: String
    let password: String
}

internal struct EtcdAuthResponse: Decodable {
    let token: String?
}

internal struct EtcdUserAddRequest: Encodable {
    let name: String
    let password: String
}

internal struct EtcdUserDeleteRequest: Encodable {
    let name: String
}

internal struct EtcdUserListResponse: Decodable {
    let users: [String]?
}

internal struct EtcdRoleAddRequest: Encodable {
    let name: String
}

internal struct EtcdRoleDeleteRequest: Encodable {
    let name: String
}

internal struct EtcdRoleListResponse: Decodable {
    let roles: [String]?
}

internal struct EtcdUserGrantRoleRequest: Encodable {
    let user: String
    let role: String
}

internal struct EtcdUserRevokeRoleRequest: Encodable {
    let user: String
    let role: String
}

// Maintenance

internal struct EtcdCompactionRequest: Encodable {
    let revision: String
    let physical: Bool?
}

// MARK: - Generic Error Response

private struct EtcdErrorResponse: Decodable {
    let error: String?
    let message: String?
    let code: Int?
}

// MARK: - HTTP Client

internal final class EtcdHttpClient: @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var session: URLSession?
    private var sessionGeneration: UInt64 = 0
    private var currentTask: URLSessionDataTask?
    private var authToken: String?
    private var _isAuthenticating = false
    private var apiPrefix = "v3"

    private static let logger = Logger(subsystem: "com.TablePro", category: "EtcdHttpClient")

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    // MARK: - Base URL

    private var tlsEnabled: Bool {
        let mode = config.additionalFields["etcdTlsMode"] ?? "Disabled"
        return mode != "Disabled"
    }

    private var baseUrl: String {
        let scheme = tlsEnabled ? "https" : "http"
        return "\(scheme)://\(config.host):\(config.port)"
    }

    private func apiPath(_ suffix: String) -> String {
        lock.lock()
        let prefix = apiPrefix
        lock.unlock()
        return "\(prefix)/\(suffix)"
    }

    // MARK: - Connection Lifecycle

    func connect() async throws {
        let tlsMode = config.additionalFields["etcdTlsMode"] ?? "Disabled"

        let urlConfig = URLSessionConfiguration.default
        urlConfig.timeoutIntervalForRequest = 30
        urlConfig.timeoutIntervalForResource = 300

        let delegate: URLSessionDelegate?
        switch tlsMode {
        case "Required":
            // Encryption without certificate verification — matches UI "Required (skip verify)"
            delegate = InsecureTlsDelegate()
        case "VerifyCA", "VerifyIdentity":
            delegate = EtcdTlsDelegate(
                caCertPath: config.additionalFields["etcdCaCertPath"],
                clientCertPath: config.additionalFields["etcdClientCertPath"],
                clientKeyPath: config.additionalFields["etcdClientKeyPath"],
                verifyHostname: tlsMode == "VerifyIdentity"
            )
        default:
            delegate = nil
        }

        lock.lock()
        if let delegate {
            session = URLSession(configuration: urlConfig, delegate: delegate, delegateQueue: nil)
        } else {
            session = URLSession(configuration: urlConfig)
        }
        lock.unlock()

        do {
            try await detectApiPrefix()
        } catch let etcdError as EtcdError {
            lock.lock()
            session?.invalidateAndCancel()
            session = nil
            lock.unlock()
            Self.logger.error("Connection test failed: \(etcdError.localizedDescription)")
            throw etcdError
        } catch {
            lock.lock()
            session?.invalidateAndCancel()
            session = nil
            lock.unlock()
            Self.logger.error("Connection test failed: \(error.localizedDescription)")
            throw EtcdError.connectionFailed(error.localizedDescription)
        }

        if !config.username.isEmpty {
            do {
                try await authenticate()
            } catch {
                lock.lock()
                session?.invalidateAndCancel()
                session = nil
                lock.unlock()
                throw error
            }
        }

        Self.logger.debug("Connected to etcd at \(self.config.host):\(self.config.port)")
    }

    func disconnect() {
        lock.lock()
        sessionGeneration &+= 1
        currentTask?.cancel()
        currentTask = nil
        session?.invalidateAndCancel()
        session = nil
        authToken = nil
        _isAuthenticating = false
        apiPrefix = "v3"
        lock.unlock()
    }

    func ping() async throws {
        let _: EtcdStatusResponse = try await post(path: apiPath("maintenance/status"), body: EmptyBody())
    }

    /// Probes etcd gateway prefixes in order and selects the first that responds
    /// with a non-404 status. Covers all etcd versions:
    ///   3.5+  → /v3/  only
    ///   3.4   → /v3/  + /v3beta/
    ///   3.3   → /v3beta/ + /v3alpha/
    ///   3.2-  → /v3alpha/ only
    private func detectApiPrefix() async throws {
        let candidates = ["v3", "v3beta", "v3alpha"]

        lock.lock()
        guard let session else {
            lock.unlock()
            throw EtcdError.notConnected
        }
        lock.unlock()

        for candidate in candidates {
            guard let url = URL(string: "\(baseUrl)/\(candidate)/maintenance/status") else {
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(EmptyBody())

            let response: URLResponse
            do {
                (_, response) = try await session.data(for: request)
            } catch {
                // Network-level failure — server is unreachable regardless of prefix
                throw error
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw EtcdError.serverError("Invalid response type")
            }

            switch httpResponse.statusCode {
            case 404:
                continue
            case 200:
                lock.lock()
                apiPrefix = candidate
                lock.unlock()
                Self.logger.debug("Detected etcd API prefix: \(candidate)")
                return
            case 401 where !config.username.isEmpty:
                // Auth required but credentials are configured — prefix is valid,
                // authenticate() will run after detection
                lock.lock()
                apiPrefix = candidate
                lock.unlock()
                Self.logger.debug("Detected etcd API prefix: \(candidate) (auth required)")
                return
            case 401:
                throw EtcdError.authFailed("Authentication required")
            default:
                Self.logger.warning("Prefix probe \(candidate) returned HTTP \(httpResponse.statusCode)")
                throw EtcdError.serverError("Unexpected HTTP \(httpResponse.statusCode) from \(candidate)/maintenance/status")
            }
        }

        throw EtcdError.serverError(
            "No supported etcd API found (tried: \(candidates.joined(separator: ", ")))"
        )
    }

    // MARK: - KV Operations

    func rangeRequest(_ req: EtcdRangeRequest) async throws -> EtcdRangeResponse {
        try await post(path: apiPath("kv/range"), body: req)
    }

    func putRequest(_ req: EtcdPutRequest) async throws -> EtcdPutResponse {
        try await post(path: apiPath("kv/put"), body: req)
    }

    func deleteRequest(_ req: EtcdDeleteRequest) async throws -> EtcdDeleteResponse {
        try await post(path: apiPath("kv/deleterange"), body: req)
    }

    // MARK: - Lease Operations

    func leaseGrant(ttl: Int64) async throws -> EtcdLeaseGrantResponse {
        let req = EtcdLeaseGrantRequest(TTL: String(ttl))
        return try await post(path: apiPath("lease/grant"), body: req)
    }

    func leaseRevoke(leaseId: Int64) async throws {
        let req = EtcdLeaseRevokeRequest(ID: String(leaseId))
        try await postVoid(path: apiPath("lease/revoke"), body: req)
    }

    func leaseTimeToLive(leaseId: Int64, keys: Bool) async throws -> EtcdLeaseTimeToLiveResponse {
        let req = EtcdLeaseTimeToLiveRequest(ID: String(leaseId), keys: keys)
        return try await post(path: apiPath("lease/timetolive"), body: req)
    }

    func leaseList() async throws -> EtcdLeaseListResponse {
        try await post(path: apiPath("lease/leases"), body: EmptyBody())
    }

    // MARK: - Cluster Operations

    func memberList() async throws -> EtcdMemberListResponse {
        try await post(path: apiPath("cluster/member/list"), body: EmptyBody())
    }

    func endpointStatus() async throws -> EtcdStatusResponse {
        try await post(path: apiPath("maintenance/status"), body: EmptyBody())
    }

    // MARK: - Watch

    func watch(key: String, prefix: Bool, timeout: TimeInterval) async throws -> [EtcdWatchEvent] {
        lock.lock()
        guard session != nil else {
            lock.unlock()
            throw EtcdError.notConnected
        }
        let token = authToken
        let generation = sessionGeneration
        lock.unlock()

        let b64Key = Self.base64Encode(key)
        var createReq = EtcdWatchCreateRequest(key: b64Key)
        if prefix {
            createReq.rangeEnd = Self.base64Encode(Self.prefixRangeEnd(for: key))
        }
        let watchReq = EtcdWatchRequest(createRequest: createReq)

        let watchPath = apiPath("watch")
        guard let url = URL(string: "\(baseUrl)/\(watchPath)") else {
            throw EtcdError.serverError("Invalid URL: \(baseUrl)/\(watchPath)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(watchReq)

        return try await withThrowingTaskGroup(of: [EtcdWatchEvent].self) { group in
            let collectedData = DataCollector()

            group.addTask {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    let result: (session: URLSession, task: URLSessionDataTask)? = self.lock.withLock {
                        guard self.sessionGeneration == generation, let currentSession = self.session else {
                            return nil
                        }
                        let dataTask = currentSession.dataTask(with: request) { data, _, error in
                            if let error {
                                // URLError.cancelled is expected when we cancel after timeout
                                if (error as? URLError)?.code == .cancelled {
                                    continuation.resume(returning: data ?? Data())
                                } else {
                                    continuation.resume(throwing: error)
                                }
                                return
                            }
                            continuation.resume(returning: data ?? Data())
                        }
                        self.currentTask = dataTask
                        return (currentSession, dataTask)
                    }
                    guard let result else {
                        continuation.resume(throwing: EtcdError.notConnected)
                        return
                    }
                    collectedData.setTask(result.task)
                    result.task.resume()
                }
                return Self.parseWatchEvents(from: data)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                collectedData.cancelTask()
                return []
            }

            var allEvents: [EtcdWatchEvent] = []
            for try await events in group {
                allEvents.append(contentsOf: events)
            }
            group.cancelAll()
            return allEvents
        }
    }

    // MARK: - Auth Management

    func authEnable() async throws {
        try await postVoid(path: apiPath("auth/enable"), body: EmptyBody())
    }

    func authDisable() async throws {
        try await postVoid(path: apiPath("auth/disable"), body: EmptyBody())
    }

    func userAdd(name: String, password: String) async throws {
        let req = EtcdUserAddRequest(name: name, password: password)
        try await postVoid(path: apiPath("auth/user/add"), body: req)
    }

    func userDelete(name: String) async throws {
        let req = EtcdUserDeleteRequest(name: name)
        try await postVoid(path: apiPath("auth/user/delete"), body: req)
    }

    func userList() async throws -> [String] {
        let resp: EtcdUserListResponse = try await post(path: apiPath("auth/user/list"), body: EmptyBody())
        return resp.users ?? []
    }

    func roleAdd(name: String) async throws {
        let req = EtcdRoleAddRequest(name: name)
        try await postVoid(path: apiPath("auth/role/add"), body: req)
    }

    func roleDelete(name: String) async throws {
        let req = EtcdRoleDeleteRequest(name: name)
        try await postVoid(path: apiPath("auth/role/delete"), body: req)
    }

    func roleList() async throws -> [String] {
        let resp: EtcdRoleListResponse = try await post(path: apiPath("auth/role/list"), body: EmptyBody())
        return resp.roles ?? []
    }

    func userGrantRole(user: String, role: String) async throws {
        let req = EtcdUserGrantRoleRequest(user: user, role: role)
        try await postVoid(path: apiPath("auth/user/grant"), body: req)
    }

    func userRevokeRole(user: String, role: String) async throws {
        let req = EtcdUserRevokeRoleRequest(user: user, role: role)
        try await postVoid(path: apiPath("auth/user/revoke"), body: req)
    }

    // MARK: - Maintenance

    func compaction(revision: Int64, physical: Bool) async throws {
        let req = EtcdCompactionRequest(revision: String(revision), physical: physical)
        try await postVoid(path: apiPath("kv/compaction"), body: req)
    }

    // MARK: - Cancellation

    func cancelCurrentRequest() {
        lock.lock()
        currentTask?.cancel()
        currentTask = nil
        lock.unlock()
    }

    // MARK: - Internal Transport

    private func post<Req: Encodable, Res: Decodable>(path: String, body: Req) async throws -> Res {
        let data = try await performRequest(path: path, body: body)
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(Res.self, from: data)
        } catch {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<unreadable>"
            Self.logger.error("Failed to decode response for \(path): \(bodyStr)")
            throw EtcdError.serverError("Failed to decode response: \(error.localizedDescription)")
        }
    }

    private func postVoid<Req: Encodable>(path: String, body: Req) async throws {
        _ = try await performRequest(path: path, body: body)
    }

    private func performRequest<Req: Encodable>(path: String, body: Req, allowReauth: Bool = true) async throws -> Data {
        lock.lock()
        guard let session else {
            lock.unlock()
            throw EtcdError.notConnected
        }
        let token = authToken
        let generation = sessionGeneration
        lock.unlock()

        guard let url = URL(string: "\(baseUrl)/\(path)") else {
            throw EtcdError.serverError("Invalid URL: \(baseUrl)/\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                self.lock.lock()
                guard self.sessionGeneration == generation, let currentSession = self.session else {
                    self.lock.unlock()
                    continuation.resume(throwing: EtcdError.notConnected)
                    return
                }
                let task = currentSession.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: EtcdError.serverError("Empty response from server"))
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
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
            throw EtcdError.serverError("Invalid response type")
        }

        if httpResponse.statusCode == 401 {
            // Attempt token refresh if not already authenticating and credentials are available
            lock.lock()
            let alreadyAuthenticating = _isAuthenticating
            lock.unlock()

            if allowReauth, !alreadyAuthenticating, !config.username.isEmpty {
                try await authenticate()
                return try await performRequest(path: path, body: body, allowReauth: false)
            }
            let errorBody = String(data: data, encoding: .utf8) ?? "Unauthorized"
            throw EtcdError.authFailed(errorBody)
        }

        if httpResponse.statusCode >= 400 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            if let errorResp = try? JSONDecoder().decode(EtcdErrorResponse.self, from: data),
               let message = errorResp.error ?? errorResp.message {
                throw EtcdError.serverError(message)
            }
            throw EtcdError.serverError(errorBody.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return data
    }

    // MARK: - Authentication

    private func authenticate() async throws {
        lock.lock()
        guard session != nil else {
            lock.unlock()
            throw EtcdError.notConnected
        }
        if _isAuthenticating {
            lock.unlock()
            return
        }
        _isAuthenticating = true
        lock.unlock()

        defer {
            lock.lock()
            _isAuthenticating = false
            lock.unlock()
        }

        let authReq = EtcdAuthRequest(name: config.username, password: config.password)
        let authPath = apiPath("auth/authenticate")
        guard let url = URL(string: "\(baseUrl)/\(authPath)") else {
            throw EtcdError.serverError("Invalid auth URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(authReq)

        lock.lock()
        guard session != nil else {
            lock.unlock()
            throw EtcdError.notConnected
        }
        let generation = sessionGeneration
        lock.unlock()

        let (data, response) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            self.lock.lock()
            guard self.sessionGeneration == generation, let currentSession = self.session else {
                self.lock.unlock()
                continuation.resume(throwing: EtcdError.notConnected)
                return
            }
            let task = currentSession.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: EtcdError.authFailed("Empty response"))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            self.lock.unlock()
            task.resume()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EtcdError.authFailed("Invalid response type")
        }

        if httpResponse.statusCode >= 400 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Authentication failed"
            throw EtcdError.authFailed(errorBody)
        }

        let authResp = try JSONDecoder().decode(EtcdAuthResponse.self, from: data)
        guard let token = authResp.token, !token.isEmpty else {
            throw EtcdError.authFailed("No token in response")
        }

        lock.lock()
        authToken = token
        lock.unlock()

        Self.logger.debug("Authenticated with etcd successfully")
    }

    // MARK: - Watch Helpers

    private static func parseWatchEvents(from data: Data) -> [EtcdWatchEvent] {
        guard !data.isEmpty else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var events: [EtcdWatchEvent] = []
        let decoder = JSONDecoder()
        let lines = text.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }

            if let streamResp = try? decoder.decode(EtcdWatchStreamResponse.self, from: lineData),
               let result = streamResp.result,
               let resultEvents = result.events {
                events.append(contentsOf: resultEvents)
            } else if let result = try? decoder.decode(EtcdWatchResult.self, from: lineData),
                      let resultEvents = result.events {
                events.append(contentsOf: resultEvents)
            }
        }
        return events
    }

    // MARK: - Base64 Helpers

    static func base64Encode(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    static func base64Decode(_ string: String) -> String {
        guard let data = Data(base64Encoded: string) else { return string }
        return String(data: data, encoding: .utf8) ?? "<b64:\(string)>"
    }

    static func prefixRangeEnd(for prefix: String) -> String {
        // Increment last byte for prefix range queries
        var bytes = Array(prefix.utf8)
        guard !bytes.isEmpty else { return "\0" }
        var i = bytes.count - 1
        while i >= 0 {
            if bytes[i] < 0xFF {
                bytes[i] += 1
                return String(bytes: Array(bytes[0 ... i]), encoding: .utf8) ?? "\0"
            }
            i -= 1
        }
        return "\0"
    }

    // MARK: - Empty Body Helper

    private struct EmptyBody: Encodable {}

    // MARK: - Data Collector for Watch

    private final class DataCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _task: URLSessionDataTask?

        func setTask(_ task: URLSessionDataTask) {
            lock.lock()
            _task = task
            lock.unlock()
        }

        func cancelTask() {
            lock.lock()
            let task = _task
            lock.unlock()
            task?.cancel()
        }
    }

    // MARK: - TLS Delegates

    private class InsecureTlsDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let serverTrust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private class EtcdTlsDelegate: NSObject, URLSessionDelegate {
        private let caCertPath: String?
        private let clientCertPath: String?
        private let clientKeyPath: String?
        private let verifyHostname: Bool

        init(
            caCertPath: String?,
            clientCertPath: String?,
            clientKeyPath: String?,
            verifyHostname: Bool
        ) {
            self.caCertPath = caCertPath
            self.clientCertPath = clientCertPath
            self.clientKeyPath = clientKeyPath
            self.verifyHostname = verifyHostname
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let authMethod = challenge.protectionSpace.authenticationMethod

            if authMethod == NSURLAuthenticationMethodServerTrust {
                handleServerTrust(challenge: challenge, completionHandler: completionHandler)
            } else if authMethod == NSURLAuthenticationMethodClientCertificate {
                handleClientCertificate(challenge: challenge, completionHandler: completionHandler)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        private func handleServerTrust(
            challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            if let caPath = caCertPath, !caPath.isEmpty {
                guard let caData = try? Data(contentsOf: URL(fileURLWithPath: caPath)),
                      let caCert = SecCertificateCreateWithData(nil, caData as CFData) else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }

                SecTrustSetAnchorCertificates(serverTrust, [caCert] as CFArray)
                SecTrustSetAnchorCertificatesOnly(serverTrust, true)
            }

            if !verifyHostname {
                // VerifyCA mode: validate the CA chain but skip hostname check
                EtcdHttpClient.logger.debug("TLS: skipping hostname verification (VerifyCA mode)")
                let policy = SecPolicyCreateBasicX509()
                SecTrustSetPolicies(serverTrust, policy)
            }

            var error: CFError?
            let isValid = SecTrustEvaluateWithError(serverTrust, &error)

            if isValid {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        private func handleClientCertificate(
            challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let certPath = clientCertPath, !certPath.isEmpty,
                  let keyPath = clientKeyPath, !keyPath.isEmpty else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            guard let p12Data = buildPkcs12(certPath: certPath, keyPath: keyPath) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            let options: [String: Any] = [kSecImportExportPassphrase as String: ""]
            var items: CFArray?
            let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

            guard status == errSecSuccess,
                  let itemArray = items as? [[String: Any]],
                  let firstItem = itemArray.first,
                  let identityRef = firstItem[kSecImportItemIdentity as String] else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            // swiftlint:disable:next force_cast
            let identity = identityRef as! SecIdentity
            let credential = URLCredential(
                identity: identity,
                certificates: nil,
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        }

        private func buildPkcs12(certPath: String, keyPath: String) -> Data? {
            // Read PEM cert and key, create identity via SecItemImport
            guard let certData = try? Data(contentsOf: URL(fileURLWithPath: certPath)),
                  let keyData = try? Data(contentsOf: URL(fileURLWithPath: keyPath)) else {
                return nil
            }

            var certItems: CFArray?
            var certFormat = SecExternalFormat.formatPEMSequence
            var certType = SecExternalItemType.itemTypeCertificate
            let certStatus = SecItemImport(
                certData as CFData,
                nil,
                &certFormat,
                &certType,
                [],
                nil,
                nil,
                &certItems
            )

            guard certStatus == errSecSuccess,
                  let certs = certItems as? [SecCertificate],
                  let cert = certs.first else {
                return nil
            }

            var keyItems: CFArray?
            var keyFormat = SecExternalFormat.formatPEMSequence
            var keyType = SecExternalItemType.itemTypePrivateKey
            let keyStatus = SecItemImport(
                keyData as CFData,
                nil,
                &keyFormat,
                &keyType,
                [],
                nil,
                nil,
                &keyItems
            )

            guard keyStatus == errSecSuccess,
                  let keys = keyItems as? [SecKey],
                  let privateKey = keys.first else {
                return nil
            }

            // Export to PKCS#12
            let exportItems: CFArray? = nil
            guard let identity = createIdentity(certificate: cert, privateKey: privateKey) else {
                return nil
            }

            var exportParams = SecItemImportExportKeyParameters()
            var p12Data: CFData?
            let exportStatus = SecItemExport(
                identity,
                .formatPKCS12,
                [],
                &exportParams,
                &p12Data
            )

            guard exportStatus == errSecSuccess, let data = p12Data else {
                _ = exportItems
                return nil
            }
            _ = exportItems
            return data as Data
        }

        private func createIdentity(certificate: SecCertificate, privateKey: SecKey) -> SecIdentity? {
            // Add cert and key to the keychain temporarily to create an identity
            let addCertQuery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
                kSecReturnRef as String: true
            ]
            var certRef: CFTypeRef?
            let certAddStatus = SecItemAdd(addCertQuery as CFDictionary, &certRef)

            let addKeyQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecValueRef as String: privateKey,
                kSecReturnRef as String: true
            ]
            var keyRef: CFTypeRef?
            let keyAddStatus = SecItemAdd(addKeyQuery as CFDictionary, &keyRef)

            var identity: SecIdentity?
            let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)

            // Clean up: only delete items that this call actually inserted
            if certAddStatus == errSecSuccess {
                let deleteCertQuery: [String: Any] = [
                    kSecClass as String: kSecClassCertificate,
                    kSecValueRef as String: certRef ?? certificate
                ]
                SecItemDelete(deleteCertQuery as CFDictionary)
            }

            if keyAddStatus == errSecSuccess {
                let deleteKeyQuery: [String: Any] = [
                    kSecClass as String: kSecClassKey,
                    kSecValueRef as String: keyRef ?? privateKey
                ]
                SecItemDelete(deleteKeyQuery as CFDictionary)
            }

            if status == errSecSuccess {
                return identity
            }
            return nil
        }
    }
}

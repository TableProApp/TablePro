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
    case fault(EtcdServerFault)
    case requestCancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to etcd")
        case .connectionFailed(let detail):
            return String(format: String(localized: "Connection failed: %@"), detail)
        case .serverError(let detail):
            return String(format: String(localized: "Server error: %@"), detail)
        case .authFailed(let detail):
            return String(format: String(localized: "Authentication failed: %@"), detail)
        case .fault(let fault):
            return fault.localizedDescription
        case .requestCancelled:
            return String(localized: "Request was cancelled")
        }
    }

    var serverFault: EtcdServerFault? {
        guard case .fault(let fault) = self else { return nil }
        return fault
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

internal struct EtcdVersionResponse: Decodable {
    let etcdserver: String?
}

// MARK: - HTTP Client

internal final class EtcdHttpClient: @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var session: URLSession?
    private var sessionGeneration: UInt64 = 0
    private var activeQueryTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var authToken: String?
    private var authTask: Task<Void, Error>?
    private var apiPrefix = "v3"
    private let queryTimeout = HttpQueryTimeoutBox()

    private static let logger = Logger(subsystem: "com.TablePro", category: "EtcdHttpClient")

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    func setQueryTimeout(_ seconds: Int) {
        queryTimeout.set(serverTimeoutSeconds: seconds)
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
        urlConfig.timeoutIntervalForRequest = HttpQueryTimeout.sessionBootstrapRequestTimeout
        urlConfig.timeoutIntervalForResource = HttpQueryTimeout.sessionResourceTimeout

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

        lock.withLock {
            if let delegate {
                session = URLSession(configuration: urlConfig, delegate: delegate, delegateQueue: nil)
            } else {
                session = URLSession(configuration: urlConfig)
            }
        }

        do {
            try await detectApiPrefix()
            if hasCredentials {
                try await refreshToken(replacing: nil)
            }
            try await healthCheck()
        } catch let etcdError as EtcdError {
            invalidateSession()
            Self.logger.error("Connection failed: \(etcdError.localizedDescription)")
            throw etcdError
        } catch {
            invalidateSession()
            Self.logger.error("Connection failed: \(error.localizedDescription)")
            throw EtcdError.connectionFailed(error.localizedDescription)
        }

        Self.logger.debug("Connected to etcd at \(self.config.host):\(self.config.port)")
    }

    private var hasCredentials: Bool {
        !config.username.isEmpty
    }

    private func invalidateSession() {
        lock.withLock {
            authTask?.cancel()
            authTask = nil
            authToken = nil
            session?.invalidateAndCancel()
            session = nil
        }
    }

    func disconnect() {
        let pending = takeActiveQueryTasks()
        lock.lock()
        sessionGeneration &+= 1
        authTask?.cancel()
        authTask = nil
        session?.invalidateAndCancel()
        session = nil
        authToken = nil
        apiPrefix = "v3"
        lock.unlock()
        for task in pending {
            task.cancel()
        }
    }

    func ping() async throws {
        try await healthCheck()
    }

    func healthCheck() async throws {
        do {
            let request = EtcdRangeRequest(
                key: Self.base64Encode(Self.healthProbeKey),
                limit: 1,
                keysOnly: true
            )
            _ = try await send(
                path: apiPath("kv/range"),
                body: request,
                cancellable: false
            )
        } catch let EtcdError.fault(fault) where fault.provesLiveSession {
            return
        }
    }

    private func detectApiPrefix() async throws {
        var sawForeignResponse = false

        for candidate in EtcdGatewayRoute.candidatePrefixes {
            switch try await probeGatewayRoute(prefix: candidate) {
            case .routed:
                lock.withLock { apiPrefix = candidate }
                Self.logger.debug("Detected etcd API prefix: \(candidate)")
                return
            case .notRouted:
                continue
            case .notEtcd:
                sawForeignResponse = true
            }
        }

        guard !sawForeignResponse else {
            throw EtcdError.connectionFailed(String(localized: """
            The server answered but is not an etcd v3 JSON gateway.
            """))
        }
        throw EtcdError.connectionFailed(String(format: String(localized: """
        No etcd v3 API found at %@. Point the connection at the client port, 2379 by default, \
        and not the peer port on 2380.
        """), "\(config.host):\(config.port)"))
    }

    private func probeGatewayRoute(prefix: String) async throws -> EtcdGatewayRoute {
        let session = try lock.withLock { () -> URLSession in
            guard let currentSession = self.session else { throw EtcdError.notConnected }
            return currentSession
        }

        let probe = EtcdRangeRequest(
            key: Self.base64Encode(Self.healthProbeKey),
            limit: 1,
            keysOnly: true
        )
        guard let url = URL(string: "\(baseUrl)/\(prefix)/kv/range") else {
            return .notRouted
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(probe)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EtcdError.serverError(String(localized: "Invalid response type"))
        }
        return EtcdGatewayRoute.classify(httpStatus: httpResponse.statusCode, body: data)
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

    func serverVersion() async -> String? {
        if let status = try? await endpointStatus(), let version = status.version {
            return version
        }
        return await gatewayVersion()
    }

    private func gatewayVersion() async -> String? {
        guard let session = lock.withLock({ self.session }) else { return nil }
        guard let url = URL(string: "\(baseUrl)/version") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = HttpQueryTimeout.sessionBootstrapRequestTimeout
        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let payload = try? JSONDecoder().decode(EtcdVersionResponse.self, from: data) else {
            return nil
        }
        return payload.etcdserver
    }

    // MARK: - Watch

    func watch(key: String, prefix: Bool, timeout: TimeInterval) async throws -> [EtcdWatchEvent] {
        try await watch(key: key, prefix: prefix, timeout: timeout, isRetry: false)
    }

    private func watch(
        key: String,
        prefix: Bool,
        timeout: TimeInterval,
        isRetry: Bool
    ) async throws -> [EtcdWatchEvent] {
        let token = try lock.withLock { () -> String? in
            guard session != nil else { throw EtcdError.notConnected }
            return authToken
        }

        var createRequest = EtcdWatchCreateRequest(key: Self.base64Encode(key))
        if prefix {
            createRequest.rangeEnd = Self.base64Encode(Self.prefixRangeEnd(for: key))
        }
        let window = Self.watchWindow(timeout)
        let watchRequest = try buildRequest(
            path: apiPath("watch"),
            body: EtcdWatchRequest(createRequest: createRequest),
            token: token,
            timeout: window + Self.watchTransportGrace
        )

        let outcome = try await streamWatch(request: watchRequest, timeout: window)

        if let status = outcome.httpStatus, status >= 400 {
            let fault = EtcdServerFault.decode(httpStatus: status, body: outcome.data)
            let recovery = EtcdRequestRecovery.action(
                for: fault,
                hasCredentials: hasCredentials,
                isRetry: isRetry
            )
            guard recovery == .reauthenticateAndRetry else { throw EtcdError.fault(fault) }
            try await refreshToken(replacing: token)
            return try await watch(key: key, prefix: prefix, timeout: timeout, isRetry: true)
        }

        return Self.parseWatchEvents(from: outcome.data)
    }

    private func streamWatch(
        request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (data: Data, httpStatus: Int?) {
        try await withThrowingTaskGroup(of: (data: Data, httpStatus: Int?)?.self) { group in
            let handle = TaskHandle()
            let generation = try lock.withLock { () -> UInt64 in
                guard session != nil else { throw EtcdError.notConnected }
                return sessionGeneration
            }

            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data, httpStatus: Int?)?, Error>) in
                    let task: URLSessionDataTask? = self.lock.withLock {
                        guard self.sessionGeneration == generation, let currentSession = self.session else {
                            return nil
                        }
                        return currentSession.dataTask(with: request) { data, response, error in
                            self.releaseActiveQueryTask(handle.task)
                            let status = (response as? HTTPURLResponse)?.statusCode
                            if let error {
                                if (error as? URLError)?.code == .cancelled {
                                    continuation.resume(returning: (data ?? Data(), status))
                                } else {
                                    continuation.resume(throwing: error)
                                }
                                return
                            }
                            continuation.resume(returning: (data ?? Data(), status))
                        }
                    }
                    guard let task else {
                        continuation.resume(throwing: EtcdError.notConnected)
                        return
                    }
                    self.registerActiveQueryTask(task)
                    handle.adopt(task)
                    task.resume()
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: Self.nanoseconds(from: timeout))
                handle.cancel()
                return nil
            }

            defer { group.cancelAll() }
            for try await outcome in group where outcome != nil {
                return outcome ?? (Data(), nil)
            }
            return (Data(), nil)
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
        for task in takeActiveQueryTasks() {
            task.cancel()
        }
    }

    // MARK: - Internal Transport

    private func post<Req: Encodable, Res: Decodable>(path: String, body: Req) async throws -> Res {
        let data = try await send(path: path, body: body)
        return try decode(data, from: path)
    }

    private func postVoid<Req: Encodable>(path: String, body: Req) async throws {
        _ = try await send(path: path, body: body)
    }

    private func decode<Res: Decodable>(_ data: Data, from path: String) throws -> Res {
        do {
            return try JSONDecoder().decode(Res.self, from: data)
        } catch {
            let bodyText = String(data: data, encoding: .utf8) ?? "<unreadable>"
            Self.logger.error("Failed to decode response for \(path): \(bodyText)")
            throw EtcdError.serverError(
                String(format: String(localized: "Failed to decode response: %@"), error.localizedDescription)
            )
        }
    }

    private func send<Req: Encodable>(
        path: String,
        body: Req,
        authorized: Bool = true,
        cancellable: Bool = true,
        isRetry: Bool = false
    ) async throws -> Data {
        let token = try lock.withLock { () -> String? in
            guard session != nil else { throw EtcdError.notConnected }
            return authToken
        }

        let request = try buildRequest(
            path: path,
            body: body,
            token: authorized ? token : nil,
            timeout: queryTimeout.requestTimeoutInterval
        )
        let (data, response) = try await perform(request: request, cancellable: cancellable)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EtcdError.serverError(String(localized: "Invalid response type"))
        }
        guard httpResponse.statusCode >= 400 else { return data }

        let fault = EtcdServerFault.decode(httpStatus: httpResponse.statusCode, body: data)
        let recovery = EtcdRequestRecovery.action(
            for: fault,
            hasCredentials: authorized && hasCredentials,
            isRetry: isRetry
        )
        guard recovery == .reauthenticateAndRetry else { throw EtcdError.fault(fault) }

        try await refreshToken(replacing: token)
        return try await send(
            path: path,
            body: body,
            authorized: authorized,
            cancellable: cancellable,
            isRetry: true
        )
    }

    private func buildRequest<Req: Encodable>(
        path: String,
        body: Req,
        token: String?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseUrl)/\(path)") else {
            throw EtcdError.serverError(
                String(format: String(localized: "Invalid URL: %@"), "\(baseUrl)/\(path)")
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func perform(
        request: URLRequest,
        cancellable: Bool
    ) async throws -> (Data, URLResponse) {
        let generation = try lock.withLock { () -> UInt64 in
            guard session != nil else { throw EtcdError.notConnected }
            return sessionGeneration
        }
        let handle = TaskHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                self.lock.lock()
                guard self.sessionGeneration == generation, let currentSession = self.session else {
                    self.lock.unlock()
                    continuation.resume(throwing: EtcdError.notConnected)
                    return
                }
                let task = currentSession.dataTask(with: request) { data, response, error in
                    if cancellable {
                        self.releaseActiveQueryTask(handle.task)
                    }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(
                            throwing: EtcdError.serverError(String(localized: "Empty response from server"))
                        )
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                if cancellable {
                    self.activeQueryTasks[ObjectIdentifier(task)] = task
                }
                self.lock.unlock()

                handle.adopt(task)
                task.resume()
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private func registerActiveQueryTask(_ task: URLSessionDataTask) {
        lock.withLock { activeQueryTasks[ObjectIdentifier(task)] = task }
    }

    private func releaseActiveQueryTask(_ task: URLSessionDataTask?) {
        guard let task else { return }
        lock.withLock { activeQueryTasks.removeValue(forKey: ObjectIdentifier(task)) }
    }

    private func takeActiveQueryTasks() -> [URLSessionDataTask] {
        lock.withLock { () -> [URLSessionDataTask] in
            let pending = Array(activeQueryTasks.values)
            activeQueryTasks.removeAll()
            return pending
        }
    }

    // MARK: - Authentication

    private func refreshToken(replacing staleToken: String?) async throws {
        enum Pending {
            case alreadyRefreshed
            case task(Task<Void, Error>)
        }

        let pending: Pending = try lock.withLock { () -> Pending in
            guard session != nil else { throw EtcdError.notConnected }
            if let authToken, authToken != staleToken { return .alreadyRefreshed }
            if let authTask { return .task(authTask) }
            let task = Task {
                defer { self.lock.withLock { self.authTask = nil } }
                try await self.authenticate()
            }
            authTask = task
            return .task(task)
        }

        guard case .task(let task) = pending else { return }
        try await task.value
    }

    private func authenticate() async throws {
        let credentials = EtcdAuthRequest(name: config.username, password: config.password)
        let data: Data
        do {
            data = try await send(
                path: apiPath("auth/authenticate"),
                body: credentials,
                authorized: false,
                cancellable: false
            )
        } catch let EtcdError.fault(fault) where fault.kind == .authNotEnabled {
            lock.withLock { authToken = nil }
            Self.logger.info("etcd reports authentication is not enabled; continuing without a token")
            return
        }

        let response: EtcdAuthResponse = try decode(data, from: "auth/authenticate")
        guard let token = response.token, !token.isEmpty else {
            throw EtcdError.authFailed(String(localized: "No token in response"))
        }

        lock.withLock { authToken = token }
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

    // MARK: - Request Handle

    private static let healthProbeKey = "health"
    private static let watchTransportGrace = TimeInterval(HttpQueryTimeout.defaultGraceSeconds)
    private static let maximumWatchWindow =
        TimeInterval(HttpQueryTimeout.resourceCeilingSeconds) - watchTransportGrace

    private static func watchWindow(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return maximumWatchWindow }
        return min(max(seconds, 0), maximumWatchWindow)
    }

    private static func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        UInt64(watchWindow(seconds) * 1_000_000_000)
    }

    private final class TaskHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var storedTask: URLSessionDataTask?
        private var cancelRequested = false

        var task: URLSessionDataTask? {
            lock.withLock { storedTask }
        }

        func adopt(_ task: URLSessionDataTask) {
            let alreadyCancelled = lock.withLock { () -> Bool in
                storedTask = task
                return cancelRequested
            }
            guard alreadyCancelled else { return }
            task.cancel()
        }

        func cancel() {
            let pending = lock.withLock { () -> URLSessionDataTask? in
                cancelRequested = true
                return storedTask
            }
            pending?.cancel()
        }
    }

    // MARK: - TLS Delegates

    private final class InsecureTlsDelegate: NSObject, URLSessionDelegate {
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

    private final class EtcdTlsDelegate: NSObject, URLSessionDelegate {
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
                  let identityRef = firstItem[kSecImportItemIdentity as String],
                  CFGetTypeID(identityRef as CFTypeRef) == SecIdentityGetTypeID() else {
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

//
//  SnowflakeConnection.swift
//  SnowflakeDriverPlugin
//
//  Implements the Snowflake connector REST protocol (session login + query
//  execution) used by the official Snowflake drivers. Supports password,
//  key-pair JWT, OAuth token, and external-browser SSO authentication.
//

import AppKit
import Compression
import Foundation
import os
import TableProPluginKit

struct SnowflakeQueryResult: Sendable {
    var columns: [SnowflakeColumnMeta]
    var rows: [[PluginCellValueBox]]
    var affectedRows: Int
    var isTruncated: Bool
    var statusMessage: String?
}

/// JSON-decoded cell value before conversion to PluginCellValue (kept Sendable for streaming).
enum PluginCellValueBox: Sendable {
    case null
    case text(String)
}

final class SnowflakeConnection: @unchecked Sendable {
    struct ResolvedParameters {
        var account: String
        var user: String
        var password: String
        var mfaPasscode: String
        var authMethod: String
        var privateKeyPath: String
        var privateKeyPassphrase: String
        var oauthToken: String
        var warehouse: String
        var database: String
        var schema: String
        var role: String
    }

    let host: String
    let params: ResolvedParameters

    private let session: URLSession
    private let lock = NSLock()
    private let heartbeat = SnowflakeHeartbeat()
    private var sessionToken: String?
    private var renewalToken: String?
    private var activeRequestIDs: Set<String> = []
    private var sequenceId = 0
    private var connectTask: Task<Void, Error>?

    var sessionFingerprint: String {
        [host, params.user.uppercased(), params.authMethod, params.role.uppercased()].joined(separator: "|")
    }

    private var _currentDatabase: String?
    private var _currentSchema: String?
    private var _currentWarehouse: String?
    private var _currentRole: String?

    private static let logger = Logger(subsystem: "com.TablePro", category: "SnowflakeConnection")
    private static let appName = "TablePro"
    private static let appVersion = "1.0.0"

    var currentDatabase: String? { lock.withLock { _currentDatabase } }
    var currentSchema: String? { lock.withLock { _currentSchema } }
    var currentWarehouse: String? { lock.withLock { _currentWarehouse } }
    var currentRole: String? { lock.withLock { _currentRole } }

    init(config: DriverConnectionConfig) {
        self.params = Self.resolveParameters(from: config)
        self.host = SnowflakeAccount.host(forAccount: params.account)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: configuration)

        self._currentDatabase = params.database.isEmpty ? nil : params.database
        self._currentSchema = params.schema.isEmpty ? nil : params.schema
        self._currentWarehouse = params.warehouse.isEmpty ? nil : params.warehouse
        self._currentRole = params.role.isEmpty ? nil : params.role
    }

    // MARK: - Parameter Resolution

    private static func resolveParameters(from config: DriverConnectionConfig) -> ResolvedParameters {
        let fields = config.additionalFields
        func field(_ key: String) -> String {
            fields[key]?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        func pick(_ custom: String, _ standard: String) -> String {
            custom.isEmpty ? standard : custom
        }
        var params = ResolvedParameters(
            account: pick(field("snowflakeAccount"), config.host),
            user: pick(field("snowflakeUser"), config.username),
            password: pick(field("snowflakePassword"), config.password),
            mfaPasscode: field("snowflakeMFAPasscode"),
            authMethod: pick(field("snowflakeAuthMethod"), "password"),
            privateKeyPath: field("snowflakePrivateKeyPath"),
            privateKeyPassphrase: field("snowflakePrivateKeyPassphrase"),
            oauthToken: field("snowflakeOAuthToken"),
            warehouse: field("snowflakeWarehouse"),
            database: pick(field("snowflakeDatabase"), config.database),
            schema: field("snowflakeSchema"),
            role: field("snowflakeRole")
        )

        let connectionName = fields["snowflakeConnectionName"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !connectionName.isEmpty, let toml = SnowflakeConnectionsTOML.parameters(forConnection: connectionName) {
            params.merge(toml: toml)
        }
        return params
    }

    // MARK: - Connection Lifecycle

    func connectIfNeeded() async throws {
        enum Pending {
            case alreadyConnected
            case task(Task<Void, Error>)
        }
        let pending: Pending = lock.withLock {
            if sessionToken != nil { return .alreadyConnected }
            if let connectTask { return .task(connectTask) }
            let task = Task {
                defer { self.lock.withLock { self.connectTask = nil } }
                try await self.connect()
            }
            connectTask = task
            return .task(task)
        }
        if case .task(let task) = pending {
            try await task.value
        }
    }

    func connect() async throws {
        switch params.authMethod {
        case "keyPair":
            try await loginWithKeyPair()
        case "oauth":
            try await login(authenticator: "OAUTH", extra: ["TOKEN": params.oauthToken])
        case "externalBrowser":
            try await loginWithExternalBrowser()
        default:
            try await loginWithPassword()
        }
    }

    func disconnect() {
        let token = lock.withLock { sessionToken }
        guard token != nil else { return }
        lock.withLock {
            sessionToken = nil
            renewalToken = nil
            activeRequestIDs.removeAll()
        }
        Task { [weak self] in
            await self?.heartbeat.stop()
            try? await self?.postLogout(token: token)
        }
    }

    func ping() async throws {
        _ = try await query("SELECT 1")
    }

    // MARK: - Authentication

    private func loginWithPassword() async throws {
        if let cachedToken = SnowflakeMFATokenStore.token(account: params.account, user: params.user) {
            do {
                try await login(
                    authenticator: "USERNAME_PASSWORD_MFA",
                    extra: ["PASSWORD": params.password, "TOKEN": cachedToken]
                )
                return
            } catch {
                SnowflakeMFATokenStore.clear(account: params.account, user: params.user)
                Self.logger.info("Cached MFA token rejected; retrying with credentials")
            }
        }

        var extra: [String: Any] = ["PASSWORD": params.password]
        let usesPasscode = !params.mfaPasscode.isEmpty
            && !SnowflakeMFATokenStore.isPasscodeRejected(params.mfaPasscode, account: params.account, user: params.user)
        if usesPasscode {
            extra["PASSCODE"] = params.mfaPasscode
            extra["EXT_AUTHN_DUO_METHOD"] = "passcode"
        }
        do {
            try await login(authenticator: "SNOWFLAKE", extra: extra)
        } catch let error as SnowflakeError {
            if usesPasscode, case .loginFailed(let code, _) = error,
               ["394507", "394633"].contains(code) {
                SnowflakeMFATokenStore.markPasscodeRejected(
                    params.mfaPasscode, account: params.account, user: params.user
                )
            }
            throw error
        }
    }

    private func loginWithKeyPair() async throws {
        let path = NSString(string: params.privateKeyPath).expandingTildeInPath
        guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw SnowflakeError.configuration("Could not read private key file at \(params.privateKeyPath)")
        }
        let auth = SnowflakeKeyPairAuth(
            account: params.account,
            user: params.user,
            privateKeyPEM: pem,
            passphrase: params.privateKeyPassphrase.isEmpty ? nil : params.privateKeyPassphrase
        )
        let jwt = try auth.makeJWT()
        try await login(authenticator: "SNOWFLAKE_JWT", extra: ["TOKEN": jwt])
    }

    private func loginWithExternalBrowser() async throws {
        if let idToken = SnowflakeIdTokenStore.token(account: params.account, user: params.user) {
            do {
                try await login(authenticator: "ID_TOKEN", extra: ["TOKEN": idToken])
                return
            } catch {
                SnowflakeIdTokenStore.clear(account: params.account, user: params.user)
                Self.logger.info("Cached SSO id token rejected; falling back to browser authentication")
            }
        }

        let server = SnowflakeBrowserAuthServer()
        let port = try await server.start()

        let authRequest: [String: Any] = [
            "data": [
                "ACCOUNT_NAME": SnowflakeAccount.issuerAccountName(forAccount: params.account),
                "LOGIN_NAME": params.user,
                "AUTHENTICATOR": "EXTERNALBROWSER",
                "BROWSER_MODE_REDIRECT_PORT": String(port)
            ]
        ]

        let authResponse: [String: Any]
        do {
            authResponse = try await postJSON(
                path: "/session/authenticator-request",
                queryItems: Self.trackingQueryItems(),
                body: authRequest,
                token: nil
            )
        } catch {
            server.stop()
            throw error
        }

        guard let data = authResponse["data"] as? [String: Any],
              let ssoURLString = data["ssoUrl"] as? String,
              let ssoURL = URL(string: ssoURLString) else {
            server.stop()
            throw SnowflakeError.authFailed("Snowflake did not return an SSO URL for browser authentication")
        }
        let proofKey = data["proofKey"] as? String ?? ""

        _ = await MainActor.run {
            NSWorkspace.shared.open(ssoURL)
        }

        let token: String
        do {
            token = try await server.waitForToken()
        } catch {
            server.stop()
            throw error
        }

        try await login(authenticator: "EXTERNALBROWSER", extra: ["TOKEN": token, "PROOF_KEY": proofKey])
    }

    private func login(authenticator: String, extra: [String: Any]) async throws {
        var data: [String: Any] = [
            "ACCOUNT_NAME": SnowflakeAccount.issuerAccountName(forAccount: params.account),
            "LOGIN_NAME": params.user,
            "CLIENT_APP_ID": Self.appName,
            "CLIENT_APP_VERSION": Self.appVersion,
            "CLIENT_ENVIRONMENT": [
                "APPLICATION": Self.appName,
                "OS": "Mac OS",
                "OCSP_MODE": "FAIL_OPEN"
            ],
            "SESSION_PARAMETERS": sessionParameters(for: authenticator)
        ]
        if authenticator != "SNOWFLAKE" {
            data["AUTHENTICATOR"] = authenticator
        }
        for (key, value) in extra {
            data[key] = value
        }

        var queryItems = Self.trackingQueryItems()
        if !params.warehouse.isEmpty { queryItems.append(URLQueryItem(name: "warehouse", value: params.warehouse)) }
        if !params.database.isEmpty { queryItems.append(URLQueryItem(name: "databaseName", value: params.database)) }
        if !params.schema.isEmpty { queryItems.append(URLQueryItem(name: "schemaName", value: params.schema)) }
        if !params.role.isEmpty { queryItems.append(URLQueryItem(name: "roleName", value: params.role)) }

        let response = try await postJSON(
            path: "/session/v1/login-request",
            queryItems: queryItems,
            body: ["data": data],
            token: nil
        )

        guard (response["success"] as? Bool) == true,
              let responseData = response["data"] as? [String: Any],
              let token = responseData["token"] as? String else {
            let message = response["message"] as? String ?? "Authentication failed"
            let code = Self.codeString(response["code"])
            if ["394507", "394508", "394633"].contains(code) {
                throw SnowflakeError.loginFailed(
                    code: code,
                    message: "\(message) Open the connection settings and refresh the MFA Passcode (TOTP) with a current code from your authenticator."
                )
            }
            throw SnowflakeError.loginFailed(code: code, message: message)
        }

        lock.withLock {
            sessionToken = token
            renewalToken = responseData["masterToken"] as? String
        }
        if let mfaToken = responseData["mfaToken"] as? String, !mfaToken.isEmpty {
            SnowflakeMFATokenStore.store(mfaToken, account: params.account, user: params.user)
            Self.logger.info("Login succeeded (\(authenticator, privacy: .public)); MFA token cached for reuse")
        } else if authenticator == "SNOWFLAKE" || authenticator == "USERNAME_PASSWORD_MFA" {
            Self.logger.info("Login succeeded (\(authenticator, privacy: .public)); no mfaToken returned; ALLOW_CLIENT_MFA_CACHING may be disabled on this account")
        }
        if let idToken = responseData["idToken"] as? String, !idToken.isEmpty {
            SnowflakeIdTokenStore.store(idToken, account: params.account, user: params.user)
            Self.logger.info("SSO id token cached; subsequent connects skip the browser")
        }
        applySessionInfo(responseData["sessionInfo"] as? [String: Any])
        startHeartbeat(masterValiditySeconds: responseData["masterValidityInSeconds"] as? Double ?? 14_400)
    }

    private func startHeartbeat(masterValiditySeconds: Double) {
        let interval = SnowflakeHeartbeat.interval(masterValiditySeconds: masterValiditySeconds)
        Task { [weak self] in
            await self?.heartbeat.start(interval: interval) { [weak self] in
                await self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        guard let token = lock.withLock({ sessionToken }) else { return }
        do {
            let response = try await postJSON(
                path: "/session/heartbeat",
                queryItems: Self.trackingQueryItems(),
                body: [:],
                token: token
            )
            if Self.codeString(response["code"]) == "390112" {
                try await renewSession()
            }
        } catch {
            Self.logger.warning("Session heartbeat failed: \(error.localizedDescription)")
        }
    }

    private func renewSession() async throws {
        let (oldToken, renewal) = lock.withLock { (sessionToken, renewalToken) }
        guard let renewal else { throw SnowflakeError.notConnected }

        let response = try await postJSON(
            path: "/session/token-request",
            queryItems: Self.trackingQueryItems(),
            body: ["oldSessionToken": oldToken ?? "", "requestType": "RENEW"],
            token: renewal
        )

        guard (response["success"] as? Bool) == true,
              let data = response["data"] as? [String: Any],
              let newToken = data["sessionToken"] as? String else {
            let message = response["message"] as? String ?? "Session renewal failed"
            throw SnowflakeError.loginFailed(code: Self.codeString(response["code"]), message: message)
        }

        lock.withLock {
            sessionToken = newToken
            if let newRenewalToken = data["masterToken"] as? String {
                renewalToken = newRenewalToken
            }
        }
    }

    private func sessionParameters(for authenticator: String) -> [String: Any] {
        var parameters: [String: Any] = [
            "CLIENT_STORE_TEMPORARY_CREDENTIAL": true,
            "CLIENT_SESSION_KEEP_ALIVE": true,
            "QUERY_TAG": Self.appName
        ]
        if authenticator == "SNOWFLAKE" || authenticator == "USERNAME_PASSWORD_MFA" {
            parameters["CLIENT_REQUEST_MFA_TOKEN"] = true
        }
        return parameters
    }

    private func postLogout(token: String?) async throws {
        guard token != nil else { return }
        _ = try? await postJSON(
            path: "/session/logout-request",
            queryItems: Self.trackingQueryItems(),
            body: [:],
            token: token
        )
    }

    // MARK: - Query Execution

    func query(_ sql: String, parameters: [PluginCellValue] = []) async throws -> SnowflakeQueryResult {
        try await withReauthentication {
            try await performQuery(sql, parameters: parameters)
        }
    }

    private func withReauthentication<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch SnowflakeError.queryFailed(let code, _) where SnowflakeError.isReauthenticationCode(code) {
            do {
                try await renewSession()
            } catch {
                lock.withLock { sessionToken = nil }
                try await connectIfNeeded()
            }
            return try await operation()
        }
    }

    func cancelAllQueries() {
        let (requestIDs, token) = lock.withLock { (activeRequestIDs, sessionToken) }
        guard !requestIDs.isEmpty, let token else { return }
        Task { [weak self] in
            for requestID in requestIDs {
                _ = try? await self?.postJSON(
                    path: "/queries/v1/abort-request",
                    queryItems: Self.trackingQueryItems(),
                    body: ["requestId": requestID],
                    token: token
                )
            }
        }
    }

    private func performQuery(_ sql: String, parameters: [PluginCellValue] = []) async throws -> SnowflakeQueryResult {
        let (data, token) = try await submitQuery(sql, parameters: parameters)
        if let resultIds = data["resultIds"] as? String, !resultIds.isEmpty {
            return try await collectMultiStatementResults(ids: resultIds, token: token)
        }
        applyFinalSessionInfo(data)
        return try await buildResult(from: data, token: token)
    }

    private func submitQuery(
        _ sql: String,
        parameters: [PluginCellValue]
    ) async throws -> (data: [String: Any], token: String) {
        guard let token = lock.withLock({ sessionToken }) else {
            throw SnowflakeError.notConnected
        }

        let requestID = UUID().uuidString.lowercased()
        let sequence = lock.withLock { () -> Int in
            sequenceId += 1
            activeRequestIDs.insert(requestID)
            return sequenceId
        }
        defer {
            lock.withLock { _ = activeRequestIDs.remove(requestID) }
        }

        var body: [String: Any] = [
            "sqlText": sql,
            "asyncExec": false,
            "sequenceId": sequence,
            "querySubmissionTime": Int(Date().timeIntervalSince1970 * 1_000)
        ]
        if !parameters.isEmpty {
            body["bindings"] = SnowflakeBindingEncoder.encode(parameters)
        } else if SnowflakeSchemaQueries.isLikelyMultiStatement(sql) {
            body["parameters"] = ["MULTI_STATEMENT_COUNT": 0]
        }

        var response = try await postJSON(
            path: "/queries/v1/query-request",
            queryItems: Self.trackingQueryItems(requestID: requestID),
            body: body,
            token: token
        )

        response = try await pollIfInProgress(response, token: token)

        guard (response["success"] as? Bool) == true else {
            let message = response["message"] as? String ?? "Query failed"
            let code = Self.codeString(response["code"])
            throw SnowflakeError.queryFailed(code: code, message: message)
        }

        guard let data = response["data"] as? [String: Any] else {
            throw SnowflakeError.invalidResponse("Query response had no data")
        }
        return (data, token)
    }

    private func collectMultiStatementResults(ids: String, token: String) async throws -> SnowflakeQueryResult {
        var combinedAffected = 0
        var last: SnowflakeQueryResult?
        for id in ids.components(separatedBy: ",") where !id.isEmpty {
            var response = try await getJSON(path: "/queries/\(id)/result", token: token)
            response = try await pollIfInProgress(response, token: token)
            guard (response["success"] as? Bool) == true,
                  let data = response["data"] as? [String: Any] else {
                let message = response["message"] as? String ?? "Statement failed"
                throw SnowflakeError.queryFailed(code: Self.codeString(response["code"]), message: message)
            }
            applyFinalSessionInfo(data)
            let result = try await buildResult(from: data, token: token)
            combinedAffected += result.affectedRows
            last = result
        }
        guard var result = last else {
            throw SnowflakeError.invalidResponse("Multi-statement response had no results")
        }
        result.affectedRows = combinedAffected
        return result
    }

    private static func trackingQueryItems(requestID: String = UUID().uuidString.lowercased()) -> [URLQueryItem] {
        [
            URLQueryItem(name: "requestId", value: requestID),
            URLQueryItem(name: "request_guid", value: UUID().uuidString.lowercased())
        ]
    }

    private static let queryPollTimeout: TimeInterval = 2_700

    private func pollIfInProgress(_ initial: [String: Any], token: String) async throws -> [String: Any] {
        var response = initial
        let deadline = Date().addingTimeInterval(Self.queryPollTimeout)
        while Self.isInProgress(response) {
            guard let data = response["data"] as? [String: Any],
                  let resultPath = data["getResultUrl"] as? String else {
                break
            }
            guard Date() < deadline else {
                throw SnowflakeError.timeout("Query did not finish within 45 minutes")
            }
            response = try await getJSON(path: resultPath, token: token)
        }
        if Self.isInProgress(response) {
            throw SnowflakeError.invalidResponse("Query is still running but Snowflake returned no result URL")
        }
        return response
    }

    private static func chunkRequestHeaders(from data: [String: Any]) -> [String: String] {
        var headers = data["chunkHeaders"] as? [String: String] ?? [:]
        if headers.isEmpty, let qrmk = data["qrmk"] as? String {
            headers["x-amz-server-side-encryption-customer-algorithm"] = "AES256"
            headers["x-amz-server-side-encryption-customer-key"] = qrmk
        }
        return headers
    }

    private func buildResult(from data: [String: Any], token: String) async throws -> SnowflakeQueryResult {
        let columns = Self.parseColumns(data["rowtype"] as? [[String: Any]] ?? [])

        var rows: [[PluginCellValueBox]] = []
        if let inlineRowset = data["rowset"] as? [[Any]] {
            rows = inlineRowset.map { row in row.map(Self.box) }
        }

        let affectedRows = Self.extractAffectedRows(columns: columns, rows: rows)

        if let chunks = data["chunks"] as? [[String: Any]], !chunks.isEmpty {
            rows.append(contentsOf: try await downloadChunks(chunks, headers: Self.chunkRequestHeaders(from: data)))
        }

        return SnowflakeQueryResult(
            columns: columns,
            rows: rows,
            affectedRows: affectedRows,
            isTruncated: false,
            statusMessage: nil
        )
    }

    struct StreamedResult {
        let columns: [SnowflakeColumnMeta]
        let inlineRows: [[PluginCellValueBox]]
        let estimatedRowCount: Int
        let batches: AsyncThrowingStream<[[PluginCellValueBox]], Error>
    }

    func queryStreamed(_ sql: String) async throws -> StreamedResult {
        let (data, _) = try await withReauthentication {
            try await submitQuery(sql, parameters: [])
        }
        applyFinalSessionInfo(data)

        let columns = Self.parseColumns(data["rowtype"] as? [[String: Any]] ?? [])
        let inlineRows = (data["rowset"] as? [[Any]] ?? []).map { row in row.map(Self.box) }
        let chunks = data["chunks"] as? [[String: Any]] ?? []
        let chunkRowCount = chunks.reduce(0) { $0 + (($1["rowCount"] as? Int) ?? 0) }
        let headers = Self.chunkRequestHeaders(from: data)
        let urls = chunks.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }

        let stream = AsyncThrowingStream<[[PluginCellValueBox]], Error> { continuation in
            guard !urls.isEmpty else {
                continuation.finish()
                return
            }
            let task = Task { [session] in
                do {
                    var buffer: [Int: [[PluginCellValueBox]]] = [:]
                    var nextToYield = 0
                    try await withThrowingTaskGroup(of: (Int, [[PluginCellValueBox]]).self) { group in
                        var nextIndex = 0
                        while nextIndex < min(Self.chunkDownloadWorkers, urls.count) {
                            let index = nextIndex
                            group.addTask {
                                (index, try await Self.downloadChunk(urls[index], headers: headers, session: session))
                            }
                            nextIndex += 1
                        }
                        while let (index, rows) = try await group.next() {
                            buffer[index] = rows
                            while let ready = buffer[nextToYield] {
                                buffer[nextToYield] = nil
                                continuation.yield(ready)
                                nextToYield += 1
                            }
                            if nextIndex < urls.count {
                                let next = nextIndex
                                group.addTask {
                                    (next, try await Self.downloadChunk(urls[next], headers: headers, session: session))
                                }
                                nextIndex += 1
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }

        return StreamedResult(
            columns: columns,
            inlineRows: inlineRows,
            estimatedRowCount: inlineRows.count + chunkRowCount,
            batches: stream
        )
    }

    private static let chunkDownloadWorkers = 4

    private func downloadChunks(_ chunks: [[String: Any]], headers: [String: String]) async throws -> [[PluginCellValueBox]] {
        let urls = chunks.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
        guard !urls.isEmpty else { return [] }

        var rowsByChunk = [[[PluginCellValueBox]]](repeating: [], count: urls.count)
        try await withThrowingTaskGroup(of: (Int, [[PluginCellValueBox]]).self) { group in
            var nextIndex = 0
            while nextIndex < min(Self.chunkDownloadWorkers, urls.count) {
                let index = nextIndex
                group.addTask { [session] in
                    (index, try await Self.downloadChunk(urls[index], headers: headers, session: session))
                }
                nextIndex += 1
            }
            while let (index, rows) = try await group.next() {
                rowsByChunk[index] = rows
                if nextIndex < urls.count {
                    let next = nextIndex
                    group.addTask { [session] in
                        (next, try await Self.downloadChunk(urls[next], headers: headers, session: session))
                    }
                    nextIndex += 1
                }
            }
        }
        return rowsByChunk.flatMap { $0 }
    }

    private static func downloadChunk(
        _ url: URL,
        headers: [String: String],
        session: URLSession
    ) async throws -> [[PluginCellValueBox]] {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (rawData, http) = try await SnowflakeHTTPClient.send(request, session: session)
        guard http.statusCode == 200 else {
            throw SnowflakeError.invalidResponse("Failed to download result chunk")
        }
        return try parseChunkRows(gunzipIfNeeded(rawData))
    }

    // MARK: - USE / Session

    func switchDatabase(to database: String) async throws {
        _ = try await query("USE DATABASE \(quoteIdentifier(database))")
        lock.withLock { _currentDatabase = database }
    }

    func switchSchema(to schema: String) async throws {
        _ = try await query("USE SCHEMA \(quoteIdentifier(schema))")
        lock.withLock { _currentSchema = schema }
    }

    func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - HTTP Helpers

    private func postJSON(
        path: String,
        queryItems: [URLQueryItem],
        body: [String: Any],
        token: String?,
        accept: String = "application/json"
    ) async throws -> [String: Any] {
        guard var components = URLComponents(string: "https://\(host)\(path)") else {
            throw SnowflakeError.configuration("Invalid Snowflake host: \(host)")
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw SnowflakeError.configuration("Could not build request URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyCommonHeaders(&request, token: token, accept: accept)

        return try await send(request)
    }

    private func getJSON(path: String, token: String?) async throws -> [String: Any] {
        let urlString = path.hasPrefix("http") ? path : "https://\(host)\(path)"
        guard let url = URL(string: urlString) else {
            throw SnowflakeError.configuration("Invalid result URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(&request, token: token)
        return try await send(request)
    }

    private func applyCommonHeaders(_ request: inout URLRequest, token: String?, accept: String = "application/json") {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("\(Self.appName)/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Snowflake Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        }
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, http) = try await SnowflakeHTTPClient.send(request, session: session)
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            Self.logger.error(
                "HTTP \(http.statusCode, privacy: .public) from \(request.url?.path ?? "?", privacy: .public): \(String(bodyText.prefix(160)), privacy: .public)"
            )
            throw SnowflakeError.invalidResponse("Snowflake returned HTTP \(http.statusCode) for \(request.url?.path ?? "request"): \(bodyText.prefix(300))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SnowflakeError.invalidResponse("Snowflake returned a non-JSON response")
        }
        return json
    }

    // MARK: - Parsing Helpers

    private func applySessionInfo(_ info: [String: Any]?) {
        guard let info else { return }
        lock.withLock {
            _currentDatabase = Self.nonEmptyString(info["databaseName"])
            _currentSchema = Self.nonEmptyString(info["schemaName"])
            _currentWarehouse = Self.nonEmptyString(info["warehouseName"])
            _currentRole = Self.nonEmptyString(info["roleName"])
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private func applyFinalSessionInfo(_ data: [String: Any]) {
        lock.withLock {
            if let value = data["finalDatabaseName"] as? String, !value.isEmpty { _currentDatabase = value }
            if let value = data["finalSchemaName"] as? String, !value.isEmpty { _currentSchema = value }
            if let value = data["finalWarehouseName"] as? String, !value.isEmpty { _currentWarehouse = value }
            if let value = data["finalRoleName"] as? String, !value.isEmpty { _currentRole = value }
        }
    }

    private static func parseColumns(_ rowtype: [[String: Any]]) -> [SnowflakeColumnMeta] {
        rowtype.map { entry in
            SnowflakeColumnMeta(
                name: entry["name"] as? String ?? "",
                internalType: entry["type"] as? String ?? "text",
                nullable: entry["nullable"] as? Bool ?? true,
                precision: entry["precision"] as? Int,
                scale: entry["scale"] as? Int,
                length: entry["length"] as? Int
            )
        }
    }

    private static func box(_ value: Any) -> PluginCellValueBox {
        if value is NSNull { return .null }
        if let string = value as? String { return .text(string) }
        if let number = value as? NSNumber { return .text(number.stringValue) }
        return .text(String(describing: value))
    }

    private static func extractAffectedRows(columns: [SnowflakeColumnMeta], rows: [[PluginCellValueBox]]) -> Int {
        guard columns.count == 1,
              columns[0].name.lowercased().contains("number of rows"),
              let firstRow = rows.first,
              case .text(let value) = firstRow.first ?? .null,
              let count = Int(value) else {
            return 0
        }
        return count
    }

    private static func parseChunkRows(_ data: Data) throws -> [[PluginCellValueBox]] {
        let candidates: [Data] = [data, Data("[".utf8) + data + Data("]".utf8)]
        for candidate in candidates {
            if let parsed = try? JSONSerialization.jsonObject(with: candidate) as? [[Any]] {
                return parsed.map { row in row.map(box) }
            }
        }
        throw SnowflakeError.invalidResponse("Could not parse result chunk JSON")
    }

    private static func codeString(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func isInProgress(_ response: [String: Any]) -> Bool {
        let code = codeString(response["code"])
        return code == "333333" || code == "333334"
    }

    // MARK: - Gzip

    private static func gunzipIfNeeded(_ data: Data) -> Data {
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            return data
        }
        let bytes = [UInt8](data)
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0, offset + 2 <= bytes.count {
            let extraLen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLen
        }
        if flags & 0x08 != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { return data }

        let deflateBytes = Array(bytes[offset..<(bytes.count - 8)])
        return inflate(deflateBytes) ?? data
    }

    private static func inflate(_ deflate: [UInt8]) -> Data? {
        guard !deflate.isEmpty else { return nil }
        var capacity = max(deflate.count * 8, 65_536)
        for _ in 0..<6 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) -> Int in
                deflate.withUnsafeBufferPointer { (inPtr: UnsafeBufferPointer<UInt8>) -> Int in
                    guard let outBase = outPtr.bindMemory(to: UInt8.self).baseAddress,
                          let inBase = inPtr.baseAddress else { return 0 }
                    return compression_decode_buffer(
                        outBase, capacity, inBase, deflate.count, nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0, written < capacity {
                output.removeSubrange(written..<output.count)
                return output
            }
            capacity *= 2
        }
        return nil
    }
}

private extension SnowflakeConnection.ResolvedParameters {
    mutating func merge(toml: [String: String]) {
        func fill(_ keyPath: WritableKeyPath<Self, String>, _ tomlKey: String) {
            if self[keyPath: keyPath].isEmpty, let value = toml[tomlKey], !value.isEmpty {
                self[keyPath: keyPath] = value
            }
        }
        fill(\.account, "account")
        fill(\.user, "user")
        fill(\.password, "password")
        fill(\.privateKeyPath, "private_key_path")
        fill(\.privateKeyPath, "private_key_file")
        fill(\.oauthToken, "token")
        fill(\.warehouse, "warehouse")
        fill(\.database, "database")
        fill(\.schema, "schema")
        fill(\.role, "role")
        if let authenticator = toml["authenticator"], authMethod == "password" {
            switch authenticator.lowercased() {
            case "snowflake_jwt": authMethod = "keyPair"
            case "oauth": authMethod = "oauth"
            case "externalbrowser": authMethod = "externalBrowser"
            default: break
            }
        }
    }
}

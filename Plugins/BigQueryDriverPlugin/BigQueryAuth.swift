//
//  BigQueryAuth.swift
//  BigQueryDriverPlugin
//
//  Authentication providers for Google BigQuery: Service Account JWT and
//  Application Default Credentials.
//

import AppKit
import Foundation
import os
import Security

// MARK: - Auth Provider Protocol

internal protocol BigQueryAuthProvider: Sendable {
    func accessToken() async throws -> String
    var projectId: String { get }
}

// MARK: - BigQuery Error

internal enum BigQueryError: Error, LocalizedError {
    case notConnected
    case authFailed(String)
    case apiError(code: Int, message: String)
    case jobFailed(String)
    case invalidResponse(String)
    case timeout(String)
    case requestCancelled
    case jobCancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to BigQuery")
        case .authFailed(let detail):
            return detail
        case .apiError(_, let message):
            return message
        case .jobFailed(let detail):
            return detail
        case .invalidResponse(let detail):
            return detail
        case .timeout(let detail):
            return detail
        case .requestCancelled:
            return String(localized: "Request was cancelled")
        case .jobCancelled:
            return String(localized: "Query was cancelled")
        }
    }
}

// MARK: - Cached Token

private struct CachedToken: Sendable {
    let token: String
    let expiresAt: Date
}

// MARK: - Service Account Auth Provider

internal final class ServiceAccountAuthProvider: @unchecked Sendable, BigQueryAuthProvider {
    let projectId: String
    private let clientEmail: String
    private let privateKeyPEM: String
    private let lock = NSLock()
    private var _cachedToken: CachedToken?
    private var _refreshTask: Task<String, Error>?
    private static let logger = Logger(subsystem: "com.TablePro", category: "BigQueryServiceAccountAuth")
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let bigqueryScope = "https://www.googleapis.com/auth/bigquery"

    init(jsonData: Data, overrideProjectId: String?) throws {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw BigQueryError.authFailed("Invalid service account JSON")
        }

        guard let email = json["client_email"] as? String else {
            throw BigQueryError.authFailed("Missing client_email in service account JSON")
        }
        guard let key = json["private_key"] as? String else {
            throw BigQueryError.authFailed("Missing private_key in service account JSON")
        }

        let saProjectId = json["project_id"] as? String ?? ""

        self.clientEmail = email
        self.privateKeyPEM = key
        self.projectId = overrideProjectId?.isEmpty == false ? overrideProjectId! : saProjectId

        if self.projectId.isEmpty {
            throw BigQueryError.authFailed("No project ID found in service account JSON or connection settings")
        }
    }

    func accessToken() async throws -> String {
        let cached: CachedToken? = lock.withLock { _cachedToken }
        if let cached, cached.expiresAt > Date().addingTimeInterval(300) {
            return cached.token
        }

        let task: Task<String, Error> = lock.withLock {
            if let existing = _refreshTask {
                return existing
            }
            let newTask = Task<String, Error> {
                defer { self.lock.withLock { self._refreshTask = nil } }
                let jwt = try self.createJWT()
                return try await self.exchangeJWTForToken(jwt)
            }
            _refreshTask = newTask
            return newTask
        }

        return try await task.value
    }

    // MARK: - JWT Creation

    private func createJWT() throws -> String {
        let now = Date()
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + 3600

        let headerJson = #"{"alg":"RS256","typ":"JWT"}"#
        let claimsJson = """
        {"iss":"\(clientEmail)","scope":"\(Self.bigqueryScope)","aud":"\(Self.tokenEndpoint)","iat":\(iat),"exp":\(exp)}
        """

        let headerB64 = base64URLEncode(Data(headerJson.utf8))
        let claimsB64 = base64URLEncode(Data(claimsJson.utf8))
        let signingInput = "\(headerB64).\(claimsB64)"

        let signature = try signRS256(data: Data(signingInput.utf8))
        let signatureB64 = base64URLEncode(signature)

        return "\(signingInput).\(signatureB64)"
    }

    private func signRS256(data: Data) throws -> Data {
        let derData = try extractDERFromPEM(privateKeyPEM)

        // Try PKCS#1 first (raw RSA key)
        if let secKey = createRSAKey(from: derData) {
            return try sign(data: data, with: secKey)
        }

        // Try stripping PKCS#8 wrapper to get PKCS#1
        if let pkcs1Data = stripPKCS8Header(derData),
           let secKey = createRSAKey(from: pkcs1Data)
        {
            return try sign(data: data, with: secKey)
        }

        throw BigQueryError.authFailed("Failed to create RSA key from private key PEM")
    }

    private func createRSAKey(from data: Data) -> SecKey? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil)
    }

    private func sign(data: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error
        ) else {
            let msg = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw BigQueryError.authFailed("Failed to sign JWT: \(msg)")
        }
        return sig as Data
    }

    private func stripPKCS8Header(_ data: Data) -> Data? {
        // PKCS#8 structure:
        // SEQUENCE {
        //   INTEGER (version)
        //   SEQUENCE { OID, NULL }  (AlgorithmIdentifier)
        //   OCTET STRING { <PKCS#1 key> }
        // }
        let bytes = Array(data)
        guard bytes.count > 26, bytes[0] == 0x30 else { return nil }

        // Walk the ASN.1 structure to find the OCTET STRING
        var offset = 0
        // Skip outer SEQUENCE tag + length
        guard let afterSeq = skipASN1TagAndLength(bytes, offset: offset) else { return nil }
        offset = afterSeq
        // Skip version INTEGER
        guard let afterVersion = skipASN1TLV(bytes, offset: offset) else { return nil }
        offset = afterVersion
        // Skip AlgorithmIdentifier SEQUENCE
        guard let afterAlgId = skipASN1TLV(bytes, offset: offset) else { return nil }
        offset = afterAlgId

        // Now we should be at the OCTET STRING
        guard offset < bytes.count, bytes[offset] == 0x04 else { return nil }
        // Skip the OCTET STRING tag + length to get to the PKCS#1 key
        guard let contentStart = skipASN1TagAndLength(bytes, offset: offset) else { return nil }

        return Data(bytes[contentStart...])
    }

    private func skipASN1TagAndLength(_ bytes: [UInt8], offset: Int) -> Int? {
        guard offset < bytes.count else { return nil }
        let pos = offset + 1 // skip tag
        guard pos < bytes.count else { return nil }

        if bytes[pos] & 0x80 == 0 {
            // Short form length
            return pos + 1
        } else {
            // Long form length
            let numLengthBytes = Int(bytes[pos] & 0x7F)
            return pos + 1 + numLengthBytes
        }
    }

    private func skipASN1TLV(_ bytes: [UInt8], offset: Int) -> Int? {
        guard offset < bytes.count else { return nil }
        var pos = offset + 1 // skip tag
        guard pos < bytes.count else { return nil }

        let length: Int
        if bytes[pos] & 0x80 == 0 {
            length = Int(bytes[pos])
            pos += 1
        } else {
            let numBytes = Int(bytes[pos] & 0x7F)
            pos += 1
            var len = 0
            for idx in 0..<numBytes {
                guard pos + idx < bytes.count else { return nil }
                len = (len << 8) | Int(bytes[pos + idx])
            }
            pos += numBytes
            length = len
        }

        return pos + length
    }

    private func extractDERFromPEM(_ pem: String) throws -> Data {
        let lines = pem.components(separatedBy: "\n")
        let base64Lines = lines.filter { line in
            !line.hasPrefix("-----") && !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let base64String = base64Lines.joined()

        guard let data = Data(base64Encoded: base64String) else {
            throw BigQueryError.authFailed("Failed to decode PEM private key")
        }
        return data
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Token Exchange

    private func exchangeJWTForToken(_ jwt: String) async throws -> String {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw BigQueryError.authFailed("Invalid token endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BigQueryError.authFailed("Invalid token response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw BigQueryError.authFailed("Token exchange failed (HTTP \(httpResponse.statusCode)): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw BigQueryError.authFailed("Missing access_token in token response")
        }

        let expiresIn = json["expires_in"] as? Int ?? 3600
        let cached = CachedToken(token: accessToken, expiresAt: Date().addingTimeInterval(Double(expiresIn)))
        lock.withLock { _cachedToken = cached }

        Self.logger.debug("Obtained access token, expires in \(expiresIn)s")
        return accessToken
    }
}

// MARK: - Application Default Credentials Provider

internal final class ADCAuthProvider: @unchecked Sendable, BigQueryAuthProvider {
    let projectId: String
    private let lock = NSLock()
    private var _cachedToken: CachedToken?
    private var _delegate: BigQueryAuthProvider?
    private let overrideProjectId: String?
    private static let logger = Logger(subsystem: "com.TablePro", category: "BigQueryADCAuth")
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    init(overrideProjectId: String?) throws {
        self.overrideProjectId = overrideProjectId

        let credPath = NSString("~/.config/gcloud/application_default_credentials.json").expandingTildeInPath

        guard let data = FileManager.default.contents(atPath: credPath) else {
            throw BigQueryError.authFailed(
                "Application default credentials not found at ~/.config/gcloud/application_default_credentials.json. " +
                "Run 'gcloud auth application-default login' first."
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BigQueryError.authFailed("Invalid application default credentials JSON")
        }

        let credType = json["type"] as? String ?? ""

        if credType == "service_account" {
            let delegate = try ServiceAccountAuthProvider(jsonData: data, overrideProjectId: overrideProjectId)
            self._delegate = delegate
            self.projectId = delegate.projectId
        } else if credType == "authorized_user" {
            guard let clientId = json["client_id"] as? String,
                  let clientSecret = json["client_secret"] as? String,
                  let refreshToken = json["refresh_token"] as? String
            else {
                throw BigQueryError.authFailed(
                    "Application default credentials missing client_id, client_secret, or refresh_token"
                )
            }

            let quotaProject = json["quota_project_id"] as? String ?? ""
            self.projectId = overrideProjectId?.isEmpty == false
                ? overrideProjectId!
                : quotaProject

            if self.projectId.isEmpty {
                throw BigQueryError.authFailed(
                    "No project ID found. Specify Project ID in the connection settings."
                )
            }

            self._delegate = AuthorizedUserDelegate(
                clientId: clientId,
                clientSecret: clientSecret,
                refreshToken: refreshToken,
                projectId: self.projectId
            )
        } else if credType == "impersonated_service_account" {
            guard let impersonationUrl = json["service_account_impersonation_url"] as? String,
                  let sourceCredentials = json["source_credentials"] as? [String: Any],
                  let sourceType = sourceCredentials["type"] as? String
            else {
                throw BigQueryError.authFailed("Invalid impersonated_service_account credentials: missing required fields")
            }

            // Resolve source credentials
            let resolvedProjectId = overrideProjectId?.isEmpty == false
                ? overrideProjectId!
                : (json["quota_project_id"] as? String ?? "")

            if resolvedProjectId.isEmpty {
                throw BigQueryError.authFailed(
                    "No project ID found. Specify Project ID in the connection settings."
                )
            }

            self.projectId = resolvedProjectId

            let sourceDelegate: BigQueryAuthProvider
            switch sourceType {
            case "authorized_user":
                guard let clientId = sourceCredentials["client_id"] as? String,
                      let clientSecret = sourceCredentials["client_secret"] as? String,
                      let refreshToken = sourceCredentials["refresh_token"] as? String
                else {
                    throw BigQueryError.authFailed("Invalid source credentials for impersonated_service_account")
                }
                sourceDelegate = AuthorizedUserDelegate(
                    clientId: clientId, clientSecret: clientSecret,
                    refreshToken: refreshToken, projectId: self.projectId
                )
            case "service_account":
                guard let saData = try? JSONSerialization.data(withJSONObject: sourceCredentials) else {
                    throw BigQueryError.authFailed("Invalid source service account credentials")
                }
                sourceDelegate = try ServiceAccountAuthProvider(jsonData: saData, overrideProjectId: self.projectId)
            default:
                throw BigQueryError.authFailed("Unsupported source credential type '\(sourceType)' in impersonated_service_account")
            }

            self._delegate = ImpersonatedServiceAccountDelegate(
                sourceProvider: sourceDelegate,
                impersonationUrl: impersonationUrl,
                projectId: self.projectId
            )
        } else {
            throw BigQueryError.authFailed(
                "Unsupported ADC credential type: '\(credType)'. " +
                "Use a service account key file or run 'gcloud auth application-default login' " +
                "to generate authorized_user credentials."
            )
        }
    }

    func accessToken() async throws -> String {
        guard let delegate = lock.withLock({ _delegate }) else {
            throw BigQueryError.authFailed("No credential delegate configured")
        }
        return try await delegate.accessToken()
    }
}

// MARK: - Authorized User Delegate

private final class AuthorizedUserDelegate: @unchecked Sendable, BigQueryAuthProvider {
    let projectId: String
    private let clientId: String
    private let clientSecret: String
    private let refreshToken: String
    private let lock = NSLock()
    private var _cachedToken: CachedToken?
    private var _refreshTask: Task<String, Error>?
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    init(clientId: String, clientSecret: String, refreshToken: String, projectId: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
        self.projectId = projectId
    }

    func accessToken() async throws -> String {
        let cached: CachedToken? = lock.withLock { _cachedToken }
        if let cached, cached.expiresAt > Date().addingTimeInterval(300) {
            return cached.token
        }

        let task: Task<String, Error> = lock.withLock {
            if let existing = _refreshTask {
                return existing
            }
            let newTask = Task<String, Error> {
                defer { self.lock.withLock { self._refreshTask = nil } }
                return try await self.performTokenRefresh()
            }
            _refreshTask = newTask
            return newTask
        }

        return try await task.value
    }

    private func performTokenRefresh() async throws -> String {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw BigQueryError.authFailed("Invalid token endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParts = [
            "grant_type=refresh_token",
            "client_id=\(urlEncode(clientId))",
            "client_secret=\(urlEncode(clientSecret))",
            "refresh_token=\(urlEncode(refreshToken))"
        ]
        request.httpBody = Data(bodyParts.joined(separator: "&").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw BigQueryError.authFailed("Token refresh failed: \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw BigQueryError.authFailed("Missing access_token in refresh response")
        }

        let expiresIn = json["expires_in"] as? Int ?? 3600
        let newToken = CachedToken(token: accessToken, expiresAt: Date().addingTimeInterval(Double(expiresIn)))
        lock.withLock { _cachedToken = newToken }

        return accessToken
    }

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
}

// MARK: - Impersonated Service Account Delegate

private final class ImpersonatedServiceAccountDelegate: @unchecked Sendable, BigQueryAuthProvider {
    let projectId: String
    private let sourceProvider: BigQueryAuthProvider
    private let impersonationUrl: String
    private let lock = NSLock()
    private var _cachedToken: CachedToken?
    private var _refreshTask: Task<String, Error>?

    init(sourceProvider: BigQueryAuthProvider, impersonationUrl: String, projectId: String) {
        self.sourceProvider = sourceProvider
        self.impersonationUrl = impersonationUrl
        self.projectId = projectId
    }

    func accessToken() async throws -> String {
        let cached: CachedToken? = lock.withLock { _cachedToken }
        if let cached, cached.expiresAt > Date().addingTimeInterval(300) {
            return cached.token
        }

        let task: Task<String, Error> = lock.withLock {
            if let existing = _refreshTask { return existing }
            let newTask = Task<String, Error> {
                defer { self.lock.withLock { self._refreshTask = nil } }
                return try await self.fetchImpersonatedToken()
            }
            _refreshTask = newTask
            return newTask
        }

        return try await task.value
    }

    private func fetchImpersonatedToken() async throws -> String {
        // Get source token
        let sourceToken = try await sourceProvider.accessToken()

        // Exchange for impersonated token
        guard let url = URL(string: impersonationUrl) else {
            throw BigQueryError.authFailed("Invalid impersonation URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(sourceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "scope": ["https://www.googleapis.com/auth/bigquery"],
            "lifetime": "3600s"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw BigQueryError.authFailed("Service account impersonation failed: \(responseBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["accessToken"] as? String,
              let expireTime = json["expireTime"] as? String
        else {
            throw BigQueryError.authFailed("Invalid impersonation response")
        }

        // Parse expireTime (ISO8601)
        let formatter = ISO8601DateFormatter()
        let expiresAt = formatter.date(from: expireTime) ?? Date().addingTimeInterval(3600)

        let newToken = CachedToken(token: accessToken, expiresAt: expiresAt)
        lock.withLock { _cachedToken = newToken }

        return accessToken
    }
}

// MARK: - OAuth 2.0 Browser Auth Provider

internal final class OAuthBrowserAuthProvider: @unchecked Sendable, BigQueryAuthProvider {
    let projectId: String
    private let clientId: String
    private let clientSecret: String
    private var _refreshToken: String?
    private let lock = NSLock()
    private var _cachedToken: CachedToken?
    private var _refreshTask: Task<String, Error>?

    private static let logger = Logger(subsystem: "com.TablePro", category: "BigQueryOAuth")
    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let scope = "https://www.googleapis.com/auth/bigquery"

    init(clientId: String, clientSecret: String, refreshToken: String?, projectId: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self._refreshToken = refreshToken
        self.projectId = projectId
    }

    func accessToken() async throws -> String {
        let cached: CachedToken? = lock.withLock { _cachedToken }
        if let cached, cached.expiresAt > Date().addingTimeInterval(300) {
            return cached.token
        }

        let task: Task<String, Error> = lock.withLock {
            if let existing = _refreshTask { return existing }
            let newTask = Task<String, Error> {
                defer { self.lock.withLock { self._refreshTask = nil } }
                let refreshToken: String? = self.lock.withLock { self._refreshToken }
                if let refreshToken {
                    return try await self.refreshAccessToken(refreshToken: refreshToken)
                } else {
                    return try await self.performBrowserAuthFlow()
                }
            }
            _refreshTask = newTask
            return newTask
        }

        return try await task.value
    }

    // MARK: - Browser Auth Flow

    private func performBrowserAuthFlow() async throws -> String {
        let server = BigQueryOAuthServer()

        // Phase 1: Start server, get port
        let port = try await server.start()

        let redirectUri = "http://127.0.0.1:\(port)"

        // Build authorization URL
        var components = URLComponents(string: Self.authEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authUrl = components?.url else {
            server.stop()
            throw BigQueryError.authFailed("Failed to build OAuth authorization URL")
        }

        // Open browser
        Self.logger.info("Opening browser for OAuth authorization")
        await NSWorkspace.shared.open(authUrl)

        // Phase 2: Wait for callback
        let code: String
        do {
            code = try await server.waitForAuthCode()
        } catch {
            server.stop()
            throw error
        }

        Self.logger.info("Received OAuth authorization code")

        // Exchange auth code for tokens
        let tokens = try await exchangeAuthCode(code, redirectUri: redirectUri)

        // Store refresh token
        lock.withLock { _refreshToken = tokens.refreshToken }

        // Cache access token
        let newToken = CachedToken(
            token: tokens.accessToken,
            expiresAt: Date().addingTimeInterval(Double(tokens.expiresIn))
        )
        lock.withLock { _cachedToken = newToken }

        Self.logger.info("OAuth authentication successful")
        return tokens.accessToken
    }

    // MARK: - Token Exchange

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
    }

    private func exchangeAuthCode(_ code: String, redirectUri: String) async throws -> TokenResponse {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw BigQueryError.authFailed("Invalid token endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParts = [
            "code=\(urlEncode(code))",
            "client_id=\(urlEncode(clientId))",
            "client_secret=\(urlEncode(clientSecret))",
            "redirect_uri=\(urlEncode(redirectUri))",
            "grant_type=authorization_code"
        ]
        request.httpBody = Data(bodyParts.joined(separator: "&").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw BigQueryError.authFailed("Token exchange failed: \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw BigQueryError.authFailed("Missing access_token in token response")
        }

        let refreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? Int ?? 3600

        if refreshToken == nil {
            Self.logger.warning("No refresh_token in response — subsequent connections will require re-authorization")
        }

        return TokenResponse(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
    }

    // MARK: - Refresh Flow

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw BigQueryError.authFailed("Invalid token endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParts = [
            "grant_type=refresh_token",
            "client_id=\(urlEncode(clientId))",
            "client_secret=\(urlEncode(clientSecret))",
            "refresh_token=\(urlEncode(refreshToken))"
        ]
        request.httpBody = Data(bodyParts.joined(separator: "&").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            // If refresh fails, clear token so next attempt triggers browser flow
            lock.withLock { _refreshToken = nil }
            throw BigQueryError.authFailed("Token refresh failed: \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw BigQueryError.authFailed("Missing access_token in refresh response")
        }

        let expiresIn = json["expires_in"] as? Int ?? 3600
        let newToken = CachedToken(token: accessToken, expiresAt: Date().addingTimeInterval(Double(expiresIn)))
        lock.withLock { _cachedToken = newToken }

        return accessToken
    }

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
}

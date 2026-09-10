import Foundation

public struct EntraDeviceAuthorization: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUri: String
    public let message: String
    public let interval: Int
    public let expiresIn: Int

    public init(
        deviceCode: String,
        userCode: String,
        verificationUri: String,
        message: String,
        interval: Int,
        expiresIn: Int
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.message = message
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

public struct EntraToken: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public enum EntraOAuthError: Error, LocalizedError, Equatable {
    case notConfigured
    case signInRequired
    case network(String)
    case unexpectedResponse
    case authorizationTimedOut
    case accessDenied
    case interactionRequired
    case refreshRejected
    case serverError(String)

    /// True when the only way forward is a fresh interactive sign-in. The host uses this to offer
    /// the browser flow instead of showing a dead-end error.
    public var needsSignIn: Bool {
        switch self {
        case .signInRequired, .interactionRequired, .refreshRejected:
            return true
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Set the Microsoft Entra ID application (client) ID for this connection.")
        case .signInRequired:
            return String(localized: "Sign in to Microsoft Entra ID to use this connection.")
        case .network(let detail):
            return String(format: String(localized: "Could not reach Microsoft Entra ID: %@"), detail)
        case .unexpectedResponse:
            return String(localized: "Microsoft Entra ID returned an unexpected response.")
        case .authorizationTimedOut:
            return String(localized: "The Microsoft Entra ID sign-in timed out before it was approved.")
        case .accessDenied:
            return String(localized: "The Microsoft Entra ID sign-in was denied.")
        case .interactionRequired:
            return String(localized: "Microsoft Entra ID needs you to sign in again.")
        case .refreshRejected:
            return String(localized: "The saved Microsoft Entra ID sign-in expired. Sign in again.")
        case .serverError(let detail):
            return String(format: String(localized: "Microsoft Entra ID sign-in failed: %@"), detail)
        }
    }
}

/// Device code flow against the Microsoft identity platform, on URLSession alone.
///
/// Device code rather than authorization code with PKCE because it needs no redirect URI and no
/// browser session owned by the app, so the same code path serves macOS and iOS and can run from
/// a plugin bundle. Unlike the deprecated resource owner password flow it still honours
/// multifactor authentication and Conditional Access.
public enum EntraOAuth {
    /// Azure SQL Database. `offline_access` is what returns a refresh token.
    ///
    /// Microsoft's own clients disagree on the form: `dotnet/SqlClient` appends `/.default` to the
    /// resource including its trailing slash and sends a doubled slash, `vscode-mssql` normalises to
    /// one. Both ship, so this follows the single-slash form. Kept as one constant because it is
    /// the first thing to try if a tenant rejects the token audience.
    public static let sqlScope = "https://database.windows.net/.default offline_access"

    public static let defaultTenant = "organizations"

    /// Refresh this far ahead of expiry. Access token lifetime is randomised between 60 and 90
    /// minutes, so a fixed margin is the only safe assumption.
    public static let refreshMargin: TimeInterval = 300

    /// Used only when a token response omits `expires_in`, which the endpoint is not supposed to do.
    public static let defaultTokenLifetime = 3_600

    public static func authorityURL(tenantId: String, path: String) -> URL? {
        let tenant = tenantId.trimmingCharacters(in: .whitespaces)
        let resolved = tenant.isEmpty ? defaultTenant : tenant
        guard let encoded = resolved.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://login.microsoftonline.com/\(encoded)/oauth2/v2.0/\(path)")
    }

    public static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
        return Data(encoded.joined(separator: "&").utf8)
    }

    private static var snakeCaseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public static func parseDeviceAuthorization(_ data: Data) throws -> EntraDeviceAuthorization {
        struct Response: Decodable {
            let deviceCode: String
            let userCode: String
            let verificationUri: String
            let message: String?
            let expiresIn: Int
            let interval: Int?
        }
        guard let response = try? snakeCaseDecoder.decode(Response.self, from: data) else {
            throw EntraOAuthError.unexpectedResponse
        }
        return EntraDeviceAuthorization(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationUri: response.verificationUri,
            message: response.message ?? "",
            interval: response.interval ?? 5,
            expiresIn: response.expiresIn
        )
    }

    public enum TokenPoll: Equatable {
        case token(EntraToken)
        case pending
        case slowDown
        case denied
        case expired
        case failed(String)
    }

    public static func interpretTokenResponse(status: Int, data: Data, now: Date) -> TokenPoll {
        if status == 200 {
            guard let token = parseToken(data, now: now) else {
                return .failed("invalid token response")
            }
            return .token(token)
        }
        struct OAuthError: Decodable { let error: String? }
        let code = (try? JSONDecoder().decode(OAuthError.self, from: data))?.error ?? "unknown_error"
        switch code {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token", "code_expired": return .expired
        default: return .failed(code)
        }
    }

    public static func parseToken(_ data: Data, now: Date) -> EntraToken? {
        struct Response: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int?
        }
        guard let response = try? snakeCaseDecoder.decode(Response.self, from: data) else { return nil }
        let lifetime = TimeInterval(response.expiresIn ?? defaultTokenLifetime)
        return EntraToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: now.addingTimeInterval(lifetime)
        )
    }

    public static func startDeviceAuthorization(
        tenantId: String,
        clientId: String,
        session: URLSession
    ) async throws -> EntraDeviceAuthorization {
        guard let url = authorityURL(tenantId: tenantId, path: "devicecode") else {
            throw EntraOAuthError.unexpectedResponse
        }
        let data = try await post(url: url, fields: [
            "client_id": clientId,
            "scope": sqlScope
        ], session: session)
        return try parseDeviceAuthorization(data)
    }

    public static func signIn(
        tenantId: String,
        clientId: String,
        openVerificationURL: @escaping @Sendable (URL, String) -> Void,
        session: URLSession = .shared
    ) async throws -> EntraToken {
        let auth = try await startDeviceAuthorization(
            tenantId: tenantId, clientId: clientId, session: session
        )
        if let url = URL(string: auth.verificationUri) {
            openVerificationURL(url, auth.userCode)
        }

        let deadline = Date().addingTimeInterval(TimeInterval(auth.expiresIn))
        var interval = max(auth.interval, 1)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            let poll = try await pollToken(
                tenantId: tenantId,
                clientId: clientId,
                deviceCode: auth.deviceCode,
                session: session
            )
            switch poll {
            case .token(let token):
                return token
            case .pending:
                continue
            case .slowDown:
                interval += 5
            case .denied:
                throw EntraOAuthError.accessDenied
            case .expired:
                throw EntraOAuthError.authorizationTimedOut
            case .failed(let detail):
                throw EntraOAuthError.serverError(detail)
            }
        }
        throw EntraOAuthError.authorizationTimedOut
    }

    public static func refresh(
        tenantId: String,
        clientId: String,
        refreshToken: String,
        session: URLSession = .shared
    ) async throws -> EntraToken {
        guard let url = authorityURL(tenantId: tenantId, path: "token") else {
            throw EntraOAuthError.unexpectedResponse
        }
        let (data, status) = try await send(url: url, fields: [
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": sqlScope
        ], session: session)

        if status == 200, let token = parseToken(data, now: Date()) {
            return token
        }
        struct OAuthError: Decodable { let error: String? }
        let code = (try? JSONDecoder().decode(OAuthError.self, from: data))?.error ?? "unknown_error"
        switch code {
        case "invalid_grant", "expired_token": throw EntraOAuthError.refreshRejected
        case "interaction_required": throw EntraOAuthError.interactionRequired
        default: throw EntraOAuthError.serverError(code)
        }
    }

    private static func pollToken(
        tenantId: String,
        clientId: String,
        deviceCode: String,
        session: URLSession
    ) async throws -> TokenPoll {
        guard let url = authorityURL(tenantId: tenantId, path: "token") else {
            return .failed("invalid token endpoint")
        }
        let (data, status) = try await send(url: url, fields: [
            "client_id": clientId,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode
        ], session: session)
        return interpretTokenResponse(status: status, data: data, now: Date())
    }

    private static func post(url: URL, fields: [String: String], session: URLSession) async throws -> Data {
        let (data, status) = try await send(url: url, fields: fields, session: session)
        guard status == 200 else {
            throw EntraOAuthError.unexpectedResponse
        }
        return data
    }

    private static func send(
        url: URL,
        fields: [String: String],
        session: URLSession
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(fields)
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw EntraOAuthError.network(error.localizedDescription)
        }
    }
}

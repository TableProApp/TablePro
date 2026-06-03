import Foundation

public struct AWSSSODeviceAuthorization: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUri: String
    public let verificationUriComplete: String
    public let interval: Int
    public let expiresIn: Int
}

public enum AWSSSOLoginError: Error, LocalizedError, Equatable {
    case network(String)
    case unexpectedResponse
    case authorizationTimedOut
    case accessDenied
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .network(let detail):
            return String(format: String(localized: "Could not reach AWS SSO: %@"), detail)
        case .unexpectedResponse:
            return String(localized: "AWS SSO returned an unexpected response.")
        case .authorizationTimedOut:
            return String(localized: "The AWS SSO sign-in timed out before it was approved.")
        case .accessDenied:
            return String(localized: "The AWS SSO sign-in was denied.")
        case .serverError(let detail):
            return String(format: String(localized: "AWS SSO sign-in failed: %@"), detail)
        }
    }
}

public enum AWSSSOLogin {
    public struct ClientRegistration: Decodable, Sendable, Equatable {
        public let clientId: String
        public let clientSecret: String
    }

    public struct TokenResponse: Decodable, Sendable, Equatable {
        public let accessToken: String
        public let expiresIn: Int
    }

    public static func registerClient(
        region: String,
        clientName: String,
        session: URLSession
    ) async throws -> ClientRegistration {
        let body: [String: Any] = [
            "clientName": clientName,
            "clientType": "public",
            "scopes": ["sso:account:access"]
        ]
        let data = try await post(path: "client/register", region: region, body: body, session: session)
        guard let registration = try? JSONDecoder().decode(ClientRegistration.self, from: data) else {
            throw AWSSSOLoginError.unexpectedResponse
        }
        return registration
    }

    public static func startDeviceAuthorization(
        region: String,
        clientId: String,
        clientSecret: String,
        startUrl: String,
        session: URLSession
    ) async throws -> AWSSSODeviceAuthorization {
        let body: [String: Any] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "startUrl": startUrl
        ]
        let data = try await post(path: "device_authorization", region: region, body: body, session: session)
        return try parseDeviceAuthorization(data)
    }

    public static func parseDeviceAuthorization(_ data: Data) throws -> AWSSSODeviceAuthorization {
        struct Response: Decodable {
            let deviceCode: String
            let userCode: String
            let verificationUri: String
            let verificationUriComplete: String
            let expiresIn: Int
            let interval: Int?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw AWSSSOLoginError.unexpectedResponse
        }
        return AWSSSODeviceAuthorization(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationUri: response.verificationUri,
            verificationUriComplete: response.verificationUriComplete,
            interval: response.interval ?? 5,
            expiresIn: response.expiresIn
        )
    }

    public enum TokenPoll: Equatable {
        case token(accessToken: String, expiresIn: Int)
        case pending
        case slowDown
        case denied
        case expired
        case failed(String)
    }

    public static func interpretTokenResponse(status: Int, data: Data) -> TokenPoll {
        if status == 200 {
            guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                return .failed("invalid token response")
            }
            return .token(accessToken: token.accessToken, expiresIn: token.expiresIn)
        }
        struct OIDCError: Decodable { let error: String? }
        let code = (try? JSONDecoder().decode(OIDCError.self, from: data))?.error ?? "unknown_error"
        switch code {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token": return .expired
        default: return .failed(code)
        }
    }

    public static func tokenCacheContents(
        accessToken: String,
        expiresAt: Date,
        region: String,
        startUrl: String
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload: [String: String] = [
            "accessToken": accessToken,
            "expiresAt": formatter.string(from: expiresAt),
            "region": region,
            "startUrl": startUrl
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    public static func writeTokenCache(
        cacheKey: String,
        accessToken: String,
        expiresAt: Date,
        region: String,
        startUrl: String,
        cacheDirectory: String
    ) throws {
        try FileManager.default.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)
        let fileName = AWSSSO.sha1Hex(Data(cacheKey.utf8)) + ".json"
        let path = (cacheDirectory as NSString).appendingPathComponent(fileName)
        let contents = try tokenCacheContents(
            accessToken: accessToken, expiresAt: expiresAt, region: region, startUrl: startUrl
        )
        try contents.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func login(
        profileName: String,
        configContents: String,
        cacheDirectory: String,
        openVerificationURL: @escaping @Sendable (URL) -> Void,
        session: URLSession = .shared
    ) async throws {
        let settings = try AWSSSO.parseProfileSettings(configContent: configContents, profileName: profileName)
        let registration = try await registerClient(region: settings.region, clientName: "TablePro", session: session)
        let auth = try await startDeviceAuthorization(
            region: settings.region,
            clientId: registration.clientId,
            clientSecret: registration.clientSecret,
            startUrl: settings.startUrl,
            session: session
        )
        if let url = URL(string: auth.verificationUriComplete) {
            openVerificationURL(url)
        }

        let deadline = Date().addingTimeInterval(TimeInterval(auth.expiresIn))
        var interval = max(auth.interval, 1)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            let poll = try await pollToken(
                region: settings.region,
                clientId: registration.clientId,
                clientSecret: registration.clientSecret,
                deviceCode: auth.deviceCode,
                session: session
            )
            switch poll {
            case .token(let accessToken, let expiresIn):
                try writeTokenCache(
                    cacheKey: settings.ssoSession ?? settings.startUrl,
                    accessToken: accessToken,
                    expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
                    region: settings.region,
                    startUrl: settings.startUrl,
                    cacheDirectory: cacheDirectory
                )
                return
            case .pending:
                continue
            case .slowDown:
                interval += 5
            case .denied:
                throw AWSSSOLoginError.accessDenied
            case .expired:
                throw AWSSSOLoginError.authorizationTimedOut
            case .failed(let detail):
                throw AWSSSOLoginError.serverError(detail)
            }
        }
        throw AWSSSOLoginError.authorizationTimedOut
    }

    private static func pollToken(
        region: String,
        clientId: String,
        clientSecret: String,
        deviceCode: String,
        session: URLSession
    ) async throws -> TokenPoll {
        let body: [String: Any] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "grantType": "urn:ietf:params:oauth:grant-type:device_code",
            "deviceCode": deviceCode
        ]
        guard let url = URL(string: "https://oidc.\(region).amazonaws.com/token") else {
            return .failed("invalid token endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return interpretTokenResponse(status: status, data: data)
        } catch {
            throw AWSSSOLoginError.network(error.localizedDescription)
        }
    }

    private static func post(
        path: String,
        region: String,
        body: [String: Any],
        session: URLSession
    ) async throws -> Data {
        guard let url = URL(string: "https://oidc.\(region).amazonaws.com/\(path)") else {
            throw AWSSSOLoginError.unexpectedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await session.data(for: request)
            return data
        } catch {
            throw AWSSSOLoginError.network(error.localizedDescription)
        }
    }
}

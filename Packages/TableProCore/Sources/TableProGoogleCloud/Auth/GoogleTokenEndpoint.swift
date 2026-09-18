import Foundation

internal struct GoogleTokenResponse: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

internal enum GoogleTokenEndpoint {
    static let requestTimeout: TimeInterval = 30
    static let defaultLifetime: TimeInterval = 3_600

    private static let formValueAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func formRequest(url: URL, fields: [(name: String, value: String)]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncoded(fields).utf8)
        return request
    }

    static func formEncoded(_ fields: [(name: String, value: String)]) -> String {
        fields
            .map { "\(percentEncoded($0.name))=\(percentEncoded($0.value))" }
            .joined(separator: "&")
    }

    static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formValueAllowed) ?? ""
    }

    static func requestToken(
        _ request: URLRequest,
        http: any GoogleHTTPClient,
        now: GoogleClock
    ) async throws -> GoogleTokenResponse {
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw GoogleAuthError.tokenRequestRejected(status: response.statusCode, oauthError: oauthError(in: data))
        }
        return try tokenResponse(from: data, receivedAt: now())
    }

    static func tokenResponse(from data: Data, receivedAt date: Date) throws -> GoogleTokenResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              !accessToken.isEmpty
        else {
            throw GoogleAuthError.invalidTokenResponse
        }
        let refreshToken = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GoogleTokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: date.addingTimeInterval(lifetime(object["expires_in"]))
        )
    }

    static func oauthError(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let code = object["error"] as? String {
            return GoogleOAuthErrorCode.sanitized(code)
        }
        if let status = object["error"] as? [String: Any] {
            return GoogleOAuthErrorCode.sanitized(status["status"] as? String)
        }
        return nil
    }

    private static func lifetime(_ raw: Any?) -> TimeInterval {
        let seconds: Double?
        switch raw {
        case let number as NSNumber:
            seconds = number.doubleValue
        case let text as String:
            seconds = Double(text)
        default:
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return defaultLifetime }
        return seconds
    }
}

import Foundation

internal struct GoogleImpersonatedTokenSource: GoogleAccessTokenSource {
    static let requestedLifetime = "3600s"

    let impersonationURL: URL
    let sourceProvider: any GoogleAccessTokenProviding
    let scopes: [String]
    let delegates: [String]
    let http: any GoogleHTTPClient
    let now: GoogleClock

    func fetchAccessToken() async throws -> GoogleAccessToken {
        guard GoogleEndpointPolicy.isTrustedGoogleAPI(impersonationURL) else {
            throw GoogleAuthError.untrustedEndpoint(impersonationURL.host ?? "")
        }
        let sourceToken = try await sourceProvider.accessToken()
        let (data, response) = try await http.send(try request(bearer: sourceToken))
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                await sourceProvider.invalidateCachedToken()
            }
            throw GoogleAuthError.tokenRequestRejected(
                status: response.statusCode,
                oauthError: GoogleTokenEndpoint.oauthError(in: data)
            )
        }
        return try token(from: data)
    }

    private func request(bearer: String) throws -> URLRequest {
        var request = URLRequest(url: impersonationURL, timeoutInterval: GoogleTokenEndpoint.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["scope": scopes, "lifetime": Self.requestedLifetime]
        if !delegates.isEmpty {
            body["delegates"] = delegates
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw GoogleAuthError.invalidTokenResponse
        }
        request.httpBody = data
        return request
    }

    private func token(from data: Data) throws -> GoogleAccessToken {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["accessToken"] as? String,
              !accessToken.isEmpty
        else {
            throw GoogleAuthError.invalidTokenResponse
        }
        let fallback = now().addingTimeInterval(GoogleTokenEndpoint.defaultLifetime)
        let expiresAt = (object["expireTime"] as? String).flatMap(GoogleRFC3339.date) ?? fallback
        return GoogleAccessToken(value: accessToken, expiresAt: expiresAt)
    }
}

internal enum GoogleRFC3339 {
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

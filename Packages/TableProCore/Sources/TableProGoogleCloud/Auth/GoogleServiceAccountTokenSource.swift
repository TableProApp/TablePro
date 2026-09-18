import Foundation

internal struct GoogleServiceAccountTokenSource: GoogleAccessTokenSource {
    static let jwtBearerGrantType = "urn:ietf:params:oauth:grant-type:jwt-bearer"
    static let assertionLifetime = 3_600

    let key: GoogleServiceAccountKey
    let scopes: [String]
    let http: any GoogleHTTPClient
    let now: GoogleClock

    func fetchAccessToken() async throws -> GoogleAccessToken {
        let assertion = try GoogleJWTAssertion.make(key: key, scopes: scopes, issuedAt: now())
        let request = GoogleTokenEndpoint.formRequest(
            url: key.tokenURI,
            fields: [
                (name: "grant_type", value: Self.jwtBearerGrantType),
                (name: "assertion", value: assertion)
            ]
        )
        let response = try await GoogleTokenEndpoint.requestToken(request, http: http, now: now)
        return GoogleAccessToken(value: response.accessToken, expiresAt: response.expiresAt)
    }
}

internal enum GoogleJWTAssertion {
    private static let header = #"{"alg":"RS256","typ":"JWT"}"#

    private struct Claims: Encodable {
        let iss: String
        let scope: String
        let aud: String
        let iat: Int
        let exp: Int
    }

    static func make(key: GoogleServiceAccountKey, scopes: [String], issuedAt: Date) throws -> String {
        let issued = Int(issuedAt.timeIntervalSince1970)
        let claims = Claims(
            iss: key.clientEmail,
            scope: scopes.joined(separator: " "),
            aud: key.tokenURI.absoluteString,
            iat: issued,
            exp: issued + GoogleServiceAccountTokenSource.assertionLifetime
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let claimsData = try? encoder.encode(claims) else { throw GoogleAuthError.signingFailed }
        let signingInput = GoogleBase64URL.encode(Data(header.utf8)) + "." + GoogleBase64URL.encode(claimsData)
        let signer = try GoogleServiceAccountSigner(privateKeyPEM: key.privateKeyPEM)
        let signature = try signer.sign(Data(signingInput.utf8))
        return signingInput + "." + GoogleBase64URL.encode(signature)
    }
}

internal enum GoogleBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

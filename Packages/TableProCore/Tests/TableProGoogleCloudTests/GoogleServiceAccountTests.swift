import Foundation
@testable import TableProGoogleCloud
import Testing

@Suite("Service account JWT and signer")
struct GoogleServiceAccountTests {
    private let rsa: TestRSAKey

    init() throws {
        rsa = try #require(TestRSAKey.shared)
    }

    @Test("Token request is form encoded with a three part RS256 assertion")
    func tokenRequestShape() async throws {
        let http = StubGoogleHTTPClient(json: #"{"access_token":"ya29.token","expires_in":3599}"#)
        let key = try GoogleServiceAccountKey.parse(json: Data(rsa.serviceAccountJSON().utf8))
        let provider = GoogleTokenProviders.serviceAccount(
            key,
            scopes: ["https://www.googleapis.com/auth/spanner.data", "https://www.googleapis.com/auth/cloud-platform"],
            http: http
        )

        let token = try await provider.accessToken()

        #expect(token == "ya29.token")
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == GoogleOAuthClient.tokenEndpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.hasPrefix("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion="))

        let fields = FormBody.fields(request)
        #expect(fields["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer")
        let assertion = try #require(fields["assertion"])
        let parts = assertion.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        #expect(parts.count == 3)

        let header = try #require(GoogleBase64URL.decode(parts[0]))
        let headerObject = try #require(try JSONSerialization.jsonObject(with: header) as? [String: Any])
        #expect(headerObject["alg"] as? String == "RS256")
        #expect(headerObject["typ"] as? String == "JWT")

        let claims = try #require(GoogleBase64URL.decode(parts[1]))
        let claimsObject = try #require(try JSONSerialization.jsonObject(with: claims) as? [String: Any])
        #expect(claimsObject["iss"] as? String == "robot@proj.iam.gserviceaccount.com")
        #expect(claimsObject["aud"] as? String == "https://oauth2.googleapis.com/token")
        #expect(
            claimsObject["scope"] as? String
                == "https://www.googleapis.com/auth/spanner.data https://www.googleapis.com/auth/cloud-platform"
        )
        let issuedAt = try #require(claimsObject["iat"] as? Int)
        let expiry = try #require(claimsObject["exp"] as? Int)
        #expect(expiry - issuedAt == 3_600)

        let signature = try #require(GoogleBase64URL.decode(parts[2]))
        #expect(rsa.verifies(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    @Test("A custom trusted token_uri becomes the audience and the request URL")
    func customTokenURI() async throws {
        let http = StubGoogleHTTPClient(json: #"{"access_token":"t","expires_in":3600}"#)
        let json = rsa.serviceAccountJSON(tokenURI: "https://sts.googleapis.com/v1/token")
        let key = try GoogleServiceAccountKey.parse(json: Data(json.utf8))
        _ = try await GoogleTokenProviders.serviceAccount(key, scopes: [], http: http).accessToken()

        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://sts.googleapis.com/v1/token")
        let assertion = try #require(FormBody.fields(request)["assertion"])
        let claims = try #require(GoogleBase64URL.decode(String(assertion.split(separator: ".")[1])))
        let object = try #require(try JSONSerialization.jsonObject(with: claims) as? [String: Any])
        #expect(object["aud"] as? String == "https://sts.googleapis.com/v1/token")
        #expect(object["scope"] as? String == GoogleOAuthClient.cloudPlatformScope)
    }

    @Test("PKCS#1 and PKCS#8 PEM keys both sign verifiable signatures")
    func signsWithBothEncodings() throws {
        let message = Data("signing input".utf8)
        for pem in [rsa.pkcs1PEM, rsa.pkcs8PEM] {
            let signature = try GoogleServiceAccountSigner(privateKeyPEM: pem).sign(message)
            #expect(rsa.verifies(signature, for: message))
        }
    }

    @Test("A PEM whose newlines arrive as escaped \\n text still decodes")
    func escapedNewlines() throws {
        let escaped = rsa.pkcs8PEM.replacingOccurrences(of: "\n", with: "\\n")
        let signature = try GoogleServiceAccountSigner(privateKeyPEM: escaped).sign(Data("x".utf8))
        #expect(rsa.verifies(signature, for: Data("x".utf8)))
    }

    @Test("PKCS#8 unwrap returns exactly the embedded PKCS#1 key")
    func unwrapsPKCS8() throws {
        let unwrapped = try GoogleServiceAccountSigner.pkcs1(fromDER: rsa.pkcs8DER)
        #expect(Array(unwrapped) == rsa.pkcs1DER)
        #expect(Array(try GoogleServiceAccountSigner.pkcs1(fromDER: rsa.pkcs1DER)) == rsa.pkcs1DER)
    }

    @Test("Malformed DER input throws malformedPrivateKey", arguments: MalformedKeyInput.derBlobs)
    func rejectsMalformedDER(_ der: [UInt8]) {
        #expect(throws: GoogleAuthError.malformedPrivateKey) {
            _ = try GoogleServiceAccountSigner.pkcs1(fromDER: der)
        }
        #expect(throws: GoogleAuthError.malformedPrivateKey) {
            _ = try GoogleServiceAccountSigner(privateKeyPEM: DERBuilder.pem(der, label: "PRIVATE KEY"))
        }
    }

    @Test("Truncating a valid PKCS#8 key at any length throws instead of trapping")
    func truncatedPKCS8() {
        let full = rsa.pkcs8DER
        for length in stride(from: 0, to: full.count, by: 7) {
            #expect(throws: GoogleAuthError.malformedPrivateKey) {
                _ = try GoogleServiceAccountSigner.pkcs1(fromDER: Array(full.prefix(length)))
            }
        }
    }

    @Test("A PKCS#8 key for another algorithm is refused")
    func nonRSAAlgorithm() {
        let ecOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        let der = DERBuilder.pkcs8(wrapping: rsa.pkcs1DER, oid: ecOID)
        #expect(throws: GoogleAuthError.malformedPrivateKey) {
            _ = try GoogleServiceAccountSigner.pkcs1(fromDER: der)
        }
    }

    @Test("Malformed PEM text throws malformedPrivateKey", arguments: MalformedKeyInput.pemTexts)
    func rejectsMalformedPEM(_ pem: String) {
        #expect(throws: GoogleAuthError.malformedPrivateKey) {
            _ = try GoogleServiceAccountSigner(privateKeyPEM: pem)
        }
    }

    @Test("A malformed key fails the token request without sending it")
    func malformedKeyFailsProvider() async throws {
        let http = StubGoogleHTTPClient(json: #"{"access_token":"t"}"#)
        let json = #"{"type":"service_account","client_email":"a@b","private_key":"-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"}"#
        let key = try GoogleServiceAccountKey.parse(json: Data(json.utf8))
        let provider = GoogleTokenProviders.serviceAccount(key, scopes: [], http: http)
        await #expect(throws: GoogleAuthError.malformedPrivateKey) {
            _ = try await provider.accessToken()
        }
        #expect(http.requests.isEmpty)
    }
}

private enum MalformedKeyInput {
    static let derBlobs: [[UInt8]] = [
        [],
        [0x30],
        [0x30, 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        [0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF, 0x02, 0x01, 0x00],
        [0x30, 0x80, 0x02, 0x01, 0x00, 0x00, 0x00],
        [0x30, 0x82, 0x01],
        [0x30, 0x05, 0x02, 0x01],
        [0x02, 0x01, 0x00],
        [0x30, 0x03, 0x04, 0x01, 0x00],
        [0x30, 0x06, 0x02, 0x01, 0x00, 0x04, 0x01, 0x00],
        [0x30, 0x08, 0x02, 0x01, 0x00, 0x30, 0x03, 0x06, 0x01, 0x2A],
        [0x30, 0x0A, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2A, 0x86, 0x48],
        [0x30, 0x03, 0x1F, 0x01, 0x00],
        [0x30, 0x03, 0x02, 0x01, 0x00, 0xFF],
        [0x30, 0x18, 0x02, 0x01, 0x00, 0x30, 0x0D, 0x06, 0x09]
            + DERBuilder.rsaEncryptionOID
            + [0x05, 0x00, 0x04, 0x84, 0x7F, 0xFF, 0xFF, 0xFF]
    ]

    static let pemTexts: [String] = [
        "",
        "-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----\n!!!not base64!!!\n-----END PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----\nMIIBVgIBADANBgkqhkiG9w0BAQEFAASCAUAwggE8AgEAAkEA",
        "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIBVgIBADAN\n-----END ENCRYPTED PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----",
        String(repeating: "A", count: 70_000)
    ]
}

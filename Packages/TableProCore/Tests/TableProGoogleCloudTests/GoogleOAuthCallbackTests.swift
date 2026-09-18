import CryptoKit
import Foundation
@testable import TableProGoogleCloud
import Testing

@Suite("PKCE")
struct GoogleOAuthPKCETests {
    @Test("The challenge matches the RFC 7636 appendix B vector")
    func rfcVector() {
        #expect(
            GoogleOAuthPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    @Test("Generated values are 32 random bytes in unpadded base64url")
    func generated() {
        let first = GoogleOAuthPKCE.generate()
        let second = GoogleOAuthPKCE.generate()
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for value in [first.verifier, first.state, first.challenge] {
            #expect(value.count == 43)
            #expect(value.unicodeScalars.allSatisfy { alphabet.contains($0) })
        }
        #expect(first.challenge == GoogleOAuthPKCE.challenge(for: first.verifier))
        #expect(first.verifier != second.verifier)
        #expect(first.state != second.state)
        #expect(first.verifier != first.state)
        let digest = Data(SHA256.hash(data: Data(first.verifier.utf8)))
        #expect(GoogleBase64URL.decode(first.challenge) == digest)
    }

    @Test("Descriptions keep the verifier and state out")
    func redacted() {
        let pkce = GoogleOAuthPKCE.generate()
        let text = String(describing: pkce)
        #expect(!text.contains(pkce.verifier))
        #expect(!text.contains(pkce.state))
    }
}

@Suite("OAuth loopback callback parsing")
struct GoogleOAuthCallbackTests {
    private let state = "expected-state_123"

    private func head(_ requestLine: String) -> String {
        requestLine + "\r\nHost: 127.0.0.1:5000\r\nUser-Agent: test\r\n\r\n"
    }

    @Test("A GET to / with the matching state yields the code")
    func matchingCode() {
        let callback = GoogleOAuthCallback.parse(
            requestHead: head("GET /?state=expected-state_123&code=4%2F0Ab_code&scope=x HTTP/1.1"),
            expectedState: state
        )
        #expect(callback == .code("4/0Ab_code"))
    }

    @Test("A bare line feed request head is accepted")
    func lineFeedOnly() {
        let callback = GoogleOAuthCallback.parse(
            requestHead: "GET /?code=abc&state=expected-state_123 HTTP/1.0\nHost: x\n\n",
            expectedState: state
        )
        #expect(callback == .code("abc"))
    }

    @Test("A mismatched or missing state is ignored")
    func mismatchedState() {
        for line in [
            "GET /?state=other&code=abc HTTP/1.1",
            "GET /?code=abc HTTP/1.1",
            "GET /?state=&code=abc HTTP/1.1",
            "GET /?state=expected-state_12&code=abc HTTP/1.1",
            "GET /?state=expected-state_123&state=expected-state_123&code=abc HTTP/1.1",
            "GET /?state=other&error=access_denied HTTP/1.1"
        ] {
            #expect(GoogleOAuthCallback.parse(requestHead: head(line), expectedState: state) == .ignore)
        }
    }

    @Test("An error with the matching state is a denial")
    func denied() {
        let callback = GoogleOAuthCallback.parse(
            requestHead: head("GET /?error=access_denied&state=expected-state_123 HTTP/1.1"),
            expectedState: state
        )
        #expect(callback == .denied("access_denied"))
    }

    @Test("A denial reason that is not a plain code is not reflected")
    func deniedUnusualReason() {
        let callback = GoogleOAuthCallback.parse(
            requestHead: head("GET /?error=%3Cscript%3E&state=expected-state_123 HTTP/1.1"),
            expectedState: state
        )
        #expect(callback == .denied("unknown"))
    }

    @Test("Methods other than GET are ignored")
    func postIgnored() {
        for method in ["POST", "HEAD", "PUT", "get"] {
            let line = "\(method) /?state=expected-state_123&code=abc HTTP/1.1"
            #expect(GoogleOAuthCallback.parse(requestHead: head(line), expectedState: state) == .ignore)
        }
    }

    @Test("Paths other than / are ignored")
    func otherPathIgnored() {
        for target in [
            "/favicon.ico?state=expected-state_123&code=abc",
            "/callback?state=expected-state_123&code=abc",
            "//evil.example/?state=expected-state_123&code=abc",
            "http://127.0.0.1/?state=expected-state_123&code=abc"
        ] {
            let line = "GET \(target) HTTP/1.1"
            #expect(GoogleOAuthCallback.parse(requestHead: head(line), expectedState: state) == .ignore)
        }
    }

    @Test("A matching state without a code or error is ignored")
    func missingCode() {
        for line in [
            "GET /?state=expected-state_123 HTTP/1.1",
            "GET /?state=expected-state_123&code= HTTP/1.1",
            "GET /?state=expected-state_123&code=a&code=b HTTP/1.1"
        ] {
            #expect(GoogleOAuthCallback.parse(requestHead: head(line), expectedState: state) == .ignore)
        }
    }

    @Test("A request head with invalid UTF-8 in a header still yields the code")
    func invalidUTF8Head() {
        var bytes = Data("GET /?state=expected-state_123&code=abc HTTP/1.1\r\nUser-Agent: ".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0xC3])
        bytes.append(Data("\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        #expect(String(bytes: bytes, encoding: .utf8) == nil)
        #expect(GoogleOAuthCallback.parse(requestHead: bytes, expectedState: state) == .code("abc"))
    }

    @Test("Undecodable bytes never satisfy a mismatched state")
    func invalidUTF8MismatchedState() {
        var bytes = Data("GET /?state=other&code=abc HTTP/1.1\r\n".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append(Data("\r\n\r\n".utf8))
        #expect(GoogleOAuthCallback.parse(requestHead: bytes, expectedState: state) == .ignore)
    }

    @Test("Malformed request heads are ignored")
    func malformed() {
        for text in ["", "\r\n\r\n", "GET", "GET /?state=expected-state_123&code=abc", "garbage \u{0} bytes"] {
            #expect(GoogleOAuthCallback.parse(requestHead: text, expectedState: state) == .ignore)
        }
        #expect(
            GoogleOAuthCallback.parse(requestHead: head("GET /?state=&code=abc HTTP/1.1"), expectedState: "") == .ignore
        )
    }
}

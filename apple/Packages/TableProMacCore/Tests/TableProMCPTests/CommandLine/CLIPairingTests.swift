import CryptoKit
import Foundation
@testable import TableProMCP
import Testing

struct CLIPairingTests {
    @Test("The verifier and the challenge are the shapes TablePro's validator accepts")
    func pkceShapes() {
        let request = CLIPairingRequest.random()
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect((43...128).contains(request.verifier.count))
        #expect(request.verifier.unicodeScalars.allSatisfy { unreserved.contains($0) })
        #expect(request.challenge.count == 43)
        let digest = Data(SHA256.hash(data: Data(request.verifier.utf8)))
        #expect(request.challenge == CLIPairingRequest.base64Url(digest))
        #expect(CLIPairingRequest.random().verifier != request.verifier)
    }

    @Test("The link asks for a read-only token and a loopback callback")
    func link() throws {
        let request = CLIPairingRequest(verifier: String(repeating: "v", count: 43), state: "s1")
        let url = try #require(request.link(callbackPort: 50_123))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "tablepro")
        #expect(components.host == "integrations")
        #expect(components.path == "/pair")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client"] == CLIClientIdentity.pairingName)
        #expect(items["challenge"] == request.challenge)
        #expect(items["redirect"] == "http://127.0.0.1:50123\(CLIPairingRequest.callbackPath)")
        #expect(items["response_mode"] == "query")
        #expect(items["state"] == "s1")
        #expect(items["scopes"] == "readOnly")
    }

    @Test("Only the callback path with this pairing's state counts")
    func callbackParsing() {
        let path = CLIPairingRequest.callbackPath
        #expect(CLIPairingCallback.parse(requestTarget: "\(path)?code=abc&state=s1", state: "s1") == .approved(code: "abc"))
        #expect(CLIPairingCallback.parse(
            requestTarget: "\(path)?error=access_denied&error_description=user_denied&state=s1",
            state: "s1"
        ) == .denied)
        #expect(CLIPairingCallback.parse(
            requestTarget: "\(path)?error=server_error&error_description=token_not_issued&state=s1",
            state: "s1"
        ) == .failed)
        #expect(CLIPairingCallback.parse(requestTarget: "\(path)?code=abc&state=other", state: "s1") == .ignored)
        #expect(CLIPairingCallback.parse(requestTarget: "/favicon.ico", state: "s1") == .ignored)
        #expect(CLIPairingCallback.parse(requestTarget: "\(path)?state=s1", state: "s1") == .ignored)
    }
}

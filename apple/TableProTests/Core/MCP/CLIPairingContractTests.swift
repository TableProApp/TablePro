import Foundation
@testable import TablePro
import TableProMCP
import Testing

@MainActor
struct CLIPairingContractTests {
    private func pairingRequest(_ request: CLIPairingRequest) throws -> PairingRequest {
        let link = try #require(request.link(callbackPort: 51_234))
        guard case .some(.success(.pairIntegration(let parsed))) = URLClassifier.classify(link) else {
            Issue.record("The app did not read the command's link as a pairing request")
            throw CancellationError()
        }
        return parsed
    }

    @Test("The app reads the command's link as a read-only pairing with a loopback callback")
    func appAcceptsTheLink() throws {
        let request = CLIPairingRequest.random()
        let parsed = try pairingRequest(request)
        #expect(parsed.clientName == CLIClientIdentity.pairingName)
        #expect(parsed.challenge == request.challenge)
        #expect(parsed.state == request.state)
        #expect(parsed.responseMode == .query)
        #expect(parsed.scopeRequest.permissions == .readOnly)
        #expect(parsed.requestedConnectionIds == nil)
        #expect(try PairingRedirectValidator.validate(parsed.redirectURL).kind == .loopbackHttp)
        try PairingPkceValidator.validateChallenge(parsed.challenge)
        try PairingPkceValidator.validateVerifier(request.verifier)
        #expect(PairingExchangeStore.sha256Base64Url(of: request.verifier) == request.challenge)
    }

    @Test("The app's approve and deny redirects reach the command as approved and denied")
    func redirectsRoundTrip() throws {
        let request = CLIPairingRequest.random()
        let parsed = try pairingRequest(request)

        let approved = try #require(PairingRedirectBuilder.success(
            base: parsed.redirectURL, code: "code-1", state: parsed.state, mode: parsed.responseMode
        ))
        #expect(CLIPairingCallback.parse(requestTarget: Self.target(of: approved), state: request.state) == .approved(code: "code-1"))

        let denied = try #require(PairingRedirectBuilder.denied(
            base: parsed.redirectURL, state: parsed.state, mode: parsed.responseMode
        ))
        #expect(CLIPairingCallback.parse(requestTarget: Self.target(of: denied), state: request.state) == .denied)
    }

    // What a browser puts on the request line for the URL it was handed.
    private static func target(of url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
        return (components?.percentEncodedPath ?? "/") + query
    }
}

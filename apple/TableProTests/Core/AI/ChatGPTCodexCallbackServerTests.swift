//
//  ChatGPTCodexCallbackServerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ChatGPTCodexCallbackTests {
    private static let state = "expected-state"

    private static func head(_ target: String, method: String = "GET") -> String {
        "\(method) \(target) HTTP/1.1\r\nHost: localhost:1455\r\n\r\n"
    }

    private static func parse(_ head: String) -> ChatGPTCodexCallback {
        ChatGPTCodexCallback.parse(requestHead: head, expectedState: state)
    }

    @Test("The redirect carrying this sign-in's state yields its code")
    func matchingStateYieldsTheCode() {
        #expect(Self.parse(Self.head("/auth/callback?code=abc&state=expected-state")) == .code("abc"))
    }

    @Test("A request that is not this sign-in's redirect is ignored", arguments: [
        "/auth/callback?code=abc&state=forged",
        "/auth/callback?code=abc",
        "/auth/callback?code=abc&state=expected-state&state=expected-state",
        "/auth/callback?error=access_denied&state=forged",
        "/auth/callback?error=access_denied",
        "/auth/callback?state=expected-state",
        "/favicon.ico",
        "/?code=abc&state=expected-state",
        "/auth/callback/extra?code=abc&state=expected-state"
    ])
    func strayRequestIsIgnored(target: String) {
        #expect(Self.parse(Self.head(target)) == .ignore)
    }

    @Test("Only a GET in origin form is read")
    func otherRequestShapesAreIgnored() {
        #expect(Self.parse(Self.head("/auth/callback?code=abc&state=expected-state", method: "POST")) == .ignore)
        #expect(Self.parse("GET http://localhost:1455/auth/callback?code=abc&state=expected-state HTTP/1.1\r\n\r\n") == .ignore)
        #expect(Self.parse("") == .ignore)
    }

    @Test("An empty expected state matches nothing")
    func emptyExpectedStateMatchesNothing() {
        let head = Self.head("/auth/callback?code=abc&state=")
        #expect(ChatGPTCodexCallback.parse(requestHead: head, expectedState: "") == .ignore)
    }

    @Test("An error redirect with this sign-in's state is a denial carrying the server's reason")
    func errorRedirectIsADenial() {
        let head = Self.head("/auth/callback?error=access_denied&error_description=User+denied+access%2E&state=expected-state")
        #expect(Self.parse(head) == .denied(error: "access_denied", description: "User denied access."))
    }

    @Test("An error sent beside a code wins, so the code is never exchanged")
    func errorWinsOverCode() {
        let head = Self.head("/auth/callback?code=abc&error=server_error&state=expected-state")
        #expect(Self.parse(head) == .denied(error: "server_error", description: nil))
    }

    @Test("The server's error text keeps only the characters RFC 6749 allows")
    func errorTextIsSanitized() {
        let head = Self.head("/auth/callback?error=%22%0Abad%5C&error_description=a%0D%0Ab%22c&state=expected-state")
        #expect(Self.parse(head) == .denied(error: "bad", description: "abc"))
    }

    @Test("A denial tells the user what the server said")
    func denialMessages() {
        typealias ServerError = ChatGPTCodexCallbackServer.ServerError
        let bare = ServerError.authorizationDenied(error: "access_denied", description: nil).errorDescription
        let explained = ServerError.authorizationDenied(error: "access_denied", description: "No Codex access").errorDescription
        let other = ServerError.authorizationDenied(error: "server_error", description: nil).errorDescription
        #expect(bare?.isEmpty == false)
        #expect(explained?.contains("No Codex access") == true)
        #expect(other?.contains("server_error") == true)
    }
}

struct ChatGPTCodexCallbackServerTests {
    private static let state = "expected-state"

    private static func status(of target: String, port: UInt16) async -> Int? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(target)") else { return nil }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let request = URLRequest(url: url, timeoutInterval: 5)
        guard let (_, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse
        else {
            return nil
        }
        return httpResponse.statusCode
    }

    @Test("Stray requests are answered and ignored, and the real redirect still completes the sign-in")
    func strayRequestsDoNotEndTheSignIn() async throws {
        let server = ChatGPTCodexCallbackServer(expectedState: Self.state, port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let code = Task { try await server.waitForCode() }

        let forged = await Self.status(of: "/auth/callback?code=forged&state=wrong", port: port)
        let deniedElsewhere = await Self.status(of: "/auth/callback?error=access_denied&state=wrong", port: port)
        let favicon = await Self.status(of: "/favicon.ico", port: port)
        let redirect = await Self.status(of: "/auth/callback?code=real-code&state=\(Self.state)", port: port)

        #expect([forged, deniedElsewhere, favicon, redirect] == [400, 400, 400, 200])
        #expect(try await code.value == "real-code")
    }

    @Test("An error redirect ends the sign-in at once with the server's reason")
    func errorRedirectFailsAtOnce() async throws {
        let server = ChatGPTCodexCallbackServer(expectedState: Self.state, port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let code = Task { try await server.waitForCode() }

        let redirect = await Self.status(
            of: "/auth/callback?error=access_denied&error_description=User+denied+access&state=\(Self.state)",
            port: port
        )

        #expect(redirect == 200)
        let expected = ChatGPTCodexCallbackServer.ServerError.authorizationDenied(
            error: "access_denied",
            description: "User denied access"
        )
        await #expect(throws: expected) {
            try await code.value
        }
    }
}

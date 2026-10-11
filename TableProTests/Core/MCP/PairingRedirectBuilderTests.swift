//
//  PairingRedirectBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct PairingRedirectBuilderTests {
    private static let code = "8D1F6C2A-0B7E-4C1D-9E5A-3F2B1C0D9E8F"
    private static let raycast = "raycast://extensions/ngoquocdat/tablepro/pair-callback"
    private static let loopback = "http://127.0.0.1:51888/callback"
    private static let modes: [PairingResponseMode] = [.legacy, .query, .context]

    private func url(_ value: String) throws -> URL {
        try #require(URL(string: value))
    }

    private func success(_ base: String, state: String? = nil, mode: PairingResponseMode) throws -> String {
        let redirect = PairingRedirectBuilder.success(base: try url(base), code: Self.code, state: state, mode: mode)
        return try #require(redirect).absoluteString
    }

    private func denied(_ base: String, state: String? = nil, mode: PairingResponseMode) throws -> String {
        let redirect = PairingRedirectBuilder.denied(base: try url(base), state: state, mode: mode)
        return try #require(redirect).absoluteString
    }

    private func parameters(of redirect: String) throws -> [String: String] {
        let items = try #require(URLComponents(string: redirect)?.queryItems)
        var parameters: [String: String] = [:]
        for item in items {
            parameters[item.name] = item.value
        }
        guard let context = parameters["context"] else { return parameters }
        let data = try #require(context.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    @Test("A legacy raycast redirect gets the context bytes shipped clients parse")
    func legacyRaycastSuccessBytes() throws {
        let redirect = try success(Self.raycast, mode: .legacy)
        #expect(redirect == "\(Self.raycast)?context=%7B%22code%22:%22\(Self.code)%22%7D")
    }

    @Test("A legacy raycast denial keeps the context bytes and the denied error")
    func legacyRaycastDeniedBytes() throws {
        let redirect = try denied(Self.raycast, mode: .legacy)
        #expect(
            redirect == "\(Self.raycast)?context=%7B%22error%22:%22denied%22,%22error_description%22:%22user_denied%22%7D"
        )
    }

    @Test("A legacy loopback redirect gets a flat code and the denied error")
    func legacyLoopbackIsFlat() throws {
        #expect(try success(Self.loopback, mode: .legacy) == "\(Self.loopback)?code=\(Self.code)")
        #expect(
            try denied(Self.loopback, mode: .legacy) == "\(Self.loopback)?error=denied&error_description=user_denied"
        )
    }

    @Test("Query mode sends a flat code and state, even to a raycast redirect")
    func queryModeIsFlat() throws {
        #expect(
            try success(Self.raycast, state: "s1", mode: .query) == "\(Self.raycast)?code=\(Self.code)&state=s1"
        )
        #expect(
            try success(Self.loopback, state: "s1", mode: .query) == "\(Self.loopback)?code=\(Self.code)&state=s1"
        )
    }

    @Test("Context mode wraps code and state in one sorted JSON parameter, whatever the scheme")
    func contextModeWraps() throws {
        let expected = "?context=%7B%22code%22:%22\(Self.code)%22,%22state%22:%22s1%22%7D"
        #expect(try success(Self.loopback, state: "s1", mode: .context) == Self.loopback + expected)
        #expect(try success(Self.raycast, state: "s1", mode: .context) == Self.raycast + expected)
    }

    @Test("Query and context denials send the RFC 6749 access_denied error")
    func standardModesDenyWithAccessDenied() throws {
        #expect(
            try denied(Self.loopback, state: "s1", mode: .query)
                == "\(Self.loopback)?error=access_denied&error_description=user_denied&state=s1"
        )
        #expect(
            try parameters(of: denied(Self.loopback, state: "s1", mode: .context)) == [
                "error": "access_denied",
                "error_description": "user_denied",
                "state": "s1"
            ]
        )
    }

    @Test("State comes back unchanged in every mode, on success and on denial")
    func stateIsEchoedEverywhere() throws {
        let state = "a+b&code=evil;c=d/é \"q\""
        for base in [Self.raycast, Self.loopback] {
            for mode in Self.modes {
                let approved = try parameters(of: success(base, state: state, mode: mode))
                #expect(approved["state"] == state)
                #expect(approved["code"] == Self.code)

                let refused = try parameters(of: denied(base, state: state, mode: mode))
                #expect(refused["state"] == state)
                #expect(refused["code"] == nil)
            }
        }
    }

    @Test("A state cannot add a parameter or turn into a space in a form decoder")
    func stateIsFullyEncoded() throws {
        let redirect = try success(Self.loopback, state: "a+b&code=evil;x", mode: .query)
        let query = try #require(URLComponents(string: redirect)?.percentEncodedQuery)
        #expect(query == "code=\(Self.code)&state=a%2Bb%26code%3Devil%3Bx")
    }

    @Test("The redirect's own query items stay byte for byte in every mode")
    func existingQueryItemsAreKept() throws {
        let base = "\(Self.loopback)?session=a%2Bb&flag"
        for mode in Self.modes {
            #expect(try success(base, state: "s1", mode: mode).hasPrefix("\(base)&"))
            #expect(try denied(base, state: "s1", mode: mode).hasPrefix("\(base)&"))
        }
        let launch = "\(Self.raycast)?launchType=background"
        #expect(try success(launch, mode: .legacy) == "\(launch)&context=%7B%22code%22:%22\(Self.code)%22%7D")
    }

    @Test("No state on the link means no state on the redirect")
    func absentStateIsNotInvented() throws {
        for base in [Self.raycast, Self.loopback] {
            for mode in Self.modes {
                #expect(try parameters(of: success(base, mode: mode))["state"] == nil)
                #expect(try parameters(of: denied(base, mode: mode))["state"] == nil)
            }
        }
    }
}

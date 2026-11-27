//
//  DeeplinkSharedLinkTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct DeeplinkSharedLinkTests {
    nonisolated private static let token = "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7cDe0fGh3"

    private func parse(_ link: String) throws -> Result<LaunchIntent, DeeplinkError> {
        DeeplinkParser.parse(try #require(URL(string: link)))
    }

    @Test("A share link carries its 43-character token")
    func carriesToken() throws {
        guard case .success(.openSharedLink(let token)) = try parse("tablepro://share?token=\(Self.token)") else {
            Issue.record("Expected .openSharedLink")
            return
        }
        #expect(token == Self.token)
    }

    @Test("Other query items are ignored")
    func ignoresOtherItems() throws {
        guard case .success(.openSharedLink(let token)) = try parse("tablepro://share?ref=web&token=\(Self.token)") else {
            Issue.record("Expected .openSharedLink")
            return
        }
        #expect(token == Self.token)
    }

    @Test("A link without a token names the missing parameter", arguments: [
        "tablepro://share", "tablepro://share?token=", "tablepro://share?t=abc"
    ])
    func missingToken(link: String) throws {
        guard case .failure(.missingRequiredParam("token")) = try parse(link) else {
            Issue.record("Expected .missingRequiredParam(\"token\") for \(link)")
            return
        }
    }

    @Test("A token that is not 43 characters of base62 is refused", arguments: [
        "short",
        String(DeeplinkSharedLinkTests.token.dropLast()),
        DeeplinkSharedLinkTests.token + "A",
        String(DeeplinkSharedLinkTests.token.dropLast()) + "-",
        String(DeeplinkSharedLinkTests.token.dropLast()) + "%2F"
    ])
    func malformedToken(token: String) throws {
        guard case .failure(.invalidParameter("token")) = try parse("tablepro://share?token=\(token)") else {
            Issue.record("Expected .invalidParameter(\"token\") for \(token)")
            return
        }
    }

    @Test("Opening a shared link puts something on screen and names no connection")
    func intentShape() {
        let intent = LaunchIntent.openSharedLink(token: Self.token)
        #expect(intent.impliesUserInterface)
        #expect(intent.targetConnectionId == nil)
    }

    @Test("Token validation accepts exactly 43 base62 characters")
    func tokenShape() {
        #expect(ShareToken.isValid(Self.token))
        #expect(!ShareToken.isValid(""))
        #expect(!ShareToken.isValid(String(repeating: "é", count: 43)))
        #expect(!ShareToken.isValid(String(repeating: "a", count: 42) + "_"))
    }
}

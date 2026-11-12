//
//  DeeplinkShareParsingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct DeeplinkShareParsingTests {
    private func token(for link: String) throws -> String? {
        let url = try #require(URL(string: link))
        guard case .success(.openShare(let token)) = DeeplinkParser.parse(url) else {
            return nil
        }
        return token
    }

    @Test("A share link carries its token")
    func shareLinkCarriesToken() throws {
        #expect(try token(for: "tablepro://share?token=abc123") == "abc123")
    }

    @Test("A percent-encoded token is decoded")
    func percentEncodedTokenIsDecoded() throws {
        #expect(try token(for: "tablepro://share?token=a%2Fb") == "a/b")
    }

    @Test("Other query items are ignored")
    func otherQueryItemsAreIgnored() throws {
        #expect(try token(for: "tablepro://share?from=web&token=abc123") == "abc123")
    }

    @Test(
        "A link without a usable token fails",
        arguments: ["tablepro://share", "tablepro://share?token=", "tablepro://share?t=abc123"]
    )
    func missingTokenFails(link: String) throws {
        let url = try #require(URL(string: link))
        guard case .failure(.missingRequiredParam("token")) = DeeplinkParser.parse(url) else {
            Issue.record("Expected .missingRequiredParam(\"token\") for \(link)")
            return
        }
    }
}

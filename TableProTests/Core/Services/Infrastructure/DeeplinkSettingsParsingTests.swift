//
//  DeeplinkSettingsParsingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct DeeplinkSettingsParsingTests {
    private func pane(for link: String) throws -> SettingsPane? {
        let url = try #require(URL(string: link))
        let outcome = URLClassifier.classify(url)
        guard case .some(.success(.openSettings(let pane))) = outcome else {
            Issue.record("Expected .openSettings for \(link), got \(String(describing: outcome))")
            return nil
        }
        return pane
    }

    @Test("A bare link asks for no pane", arguments: ["tablepro://settings", "tablepro://settings/"])
    func bareLinkAsksForNoPane(link: String) throws {
        #expect(try pane(for: link) == nil)
    }

    @Test("A known id opens its pane")
    func knownIdOpensItsPane() throws {
        #expect(try pane(for: "tablepro://settings/mcp") == .mcp)
        #expect(try pane(for: "tablepro://settings/plugins") == .plugins)
        #expect(try pane(for: "tablepro://settings/license") == .account)
    }

    @Test(
        "An unknown id asks for no pane instead of failing",
        arguments: ["tablepro://settings/nope", "tablepro://settings/MCP", "tablepro://settings/account"]
    )
    func unknownIdAsksForNoPane(link: String) throws {
        #expect(try pane(for: link) == nil)
    }

    @Test("Path segments after the pane are ignored")
    func extraSegmentsAreIgnored() throws {
        #expect(try pane(for: "tablepro://settings/mcp/authentication") == .mcp)
        #expect(try pane(for: "tablepro://settings/ai/providers/openai/") == .ai)
    }

    @Test("Query items are ignored")
    func queryIsIgnored() throws {
        #expect(try pane(for: "tablepro://settings/sync?section=status") == .sync)
        #expect(try pane(for: "tablepro://settings?pane=mcp") == nil)
    }

    @Test("A percent-encoded id is decoded before matching")
    func percentEncodedIdIsDecoded() throws {
        #expect(try pane(for: "tablepro://settings/%6Dcp") == .mcp)
    }
}

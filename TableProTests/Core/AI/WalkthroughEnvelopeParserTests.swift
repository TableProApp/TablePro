//
//  WalkthroughEnvelopeParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("WalkthroughEnvelopeParser")
struct WalkthroughEnvelopeParserTests {
    private let open = WalkthroughEnvelopeParser.openFence
    private let close = WalkthroughEnvelopeParser.closeFence

    private func wrap(_ json: String, prose: String = "Here is the change.", includeClose: Bool = true) -> String {
        var text = "\(prose)\n\n\(open)\n\(json)"
        if includeClose { text += "\n\(close)" }
        return text
    }

    @Test("Parses a well-formed envelope")
    func parsesWellFormed() {
        let json = #"""
        {
          "afterSQL": "SELECT id FROM t",
          "steps": [
            {
              "title": "Trim columns", "why": "Less IO",
              "importance": "critical", "changeType": "modification",
              "anchor": { "side": "after", "startLine": 1, "endLine": 1 }
            }
          ]
        }
        """#
        let envelope = WalkthroughEnvelopeParser.parse(from: wrap(json))
        #expect(envelope?.afterSQL == "SELECT id FROM t")
        #expect(envelope?.steps.count == 1)
        #expect(envelope?.steps.first?.importance == .critical)
        #expect(envelope?.steps.first?.anchor?.side == .after)
    }

    @Test("Parses when the JSON is wrapped in a code fence")
    func parsesCodeFencedJSON() {
        let json = "```json\n{\"afterSQL\":null,\"steps\":[]}\n```"
        let envelope = WalkthroughEnvelopeParser.parse(from: wrap(json))
        #expect(envelope != nil)
        #expect(envelope?.afterSQL == nil)
        #expect(envelope?.steps.isEmpty == true)
    }

    @Test("Parses even without a closing fence when the JSON is valid")
    func parsesWithoutClosingFence() {
        let json = #"{"afterSQL":"SELECT 1","steps":[]}"#
        let envelope = WalkthroughEnvelopeParser.parse(from: wrap(json, includeClose: false))
        #expect(envelope?.afterSQL == "SELECT 1")
    }

    @Test("Malformed JSON between fences returns nil")
    func malformedReturnsNil() {
        let envelope = WalkthroughEnvelopeParser.parse(from: wrap("{ not valid json"))
        #expect(envelope == nil)
    }

    @Test("Text with no open fence returns nil")
    func noFenceReturnsNil() {
        #expect(WalkthroughEnvelopeParser.parse(from: "Just a plain explanation, no JSON.") == nil)
    }

    @Test("A null afterSQL decodes to nil")
    func nullAfterSQL() {
        let json = #"""
        {
          "afterSQL": null,
          "steps": [
            { "title": "a", "why": "b", "importance": "normal", "changeType": "explanation" }
          ]
        }
        """#
        let envelope = WalkthroughEnvelopeParser.parse(from: wrap(json))
        #expect(envelope?.afterSQL == nil)
        #expect(envelope?.steps.count == 1)
        #expect(envelope?.steps.first?.anchor == nil)
    }

    @Test("Steps receive unique synthesized ids")
    func uniqueStepIDs() {
        let json = #"""
        {
          "afterSQL": null,
          "steps": [
            { "title": "a", "why": "x", "importance": "normal", "changeType": "explanation" },
            { "title": "b", "why": "y", "importance": "context", "changeType": "explanation" }
          ]
        }
        """#
        let envelope = WalkthroughEnvelopeParser.parse(from: wrap(json))
        let ids = envelope?.steps.map(\.id) ?? []
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
    }

    @Test("stripFence removes the fenced block and trims prose")
    func stripFenceRemovesBlock() {
        let text = wrap(#"{"afterSQL":null,"steps":[]}"#, prose: "Explanation text.")
        #expect(WalkthroughEnvelopeParser.stripFence(from: text) == "Explanation text.")
    }

    @Test("stripFence returns the input unchanged when there is no fence")
    func stripFenceNoFence() {
        #expect(WalkthroughEnvelopeParser.stripFence(from: "no fence here") == "no fence here")
    }
}

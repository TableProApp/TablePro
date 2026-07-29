//
//  ChatContentBlockWireWalkthroughTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ChatContentBlockWire SQL walkthrough")
struct ChatContentBlockWireWalkthroughTests {
    private func sampleBlock() -> SqlWalkthroughBlock {
        SqlWalkthroughBlock(
            beforeSQL: "SELECT * FROM users",
            envelope: SqlWalkthroughEnvelope(
                afterSQL: "SELECT id FROM users",
                steps: [
                    SqlWalkthroughStep(
                        title: "Select only the columns you need",
                        why: "Avoids reading unused data off disk",
                        importance: .critical,
                        changeType: .modification,
                        anchor: SqlWalkthroughAnchor(side: .after, startLine: 1, endLine: 1)
                    )
                ]
            ),
            diffStyle: .split
        )
    }

    @Test("A walkthrough block round-trips through the wire encoding")
    func roundTrips() throws {
        let wire = ChatContentBlockWire.sqlWalkthrough(sampleBlock())
        let data = try JSONEncoder().encode(wire)
        let decoded = try JSONDecoder().decode(ChatContentBlockWire.self, from: data)
        #expect(decoded.kind == wire.kind)
    }

    @Test("Diff style survives the round trip")
    func diffStylePersists() throws {
        let wire = ChatContentBlockWire.sqlWalkthrough(sampleBlock())
        let data = try JSONEncoder().encode(wire)
        let decoded = try JSONDecoder().decode(ChatContentBlockWire.self, from: data)
        guard case .sqlWalkthrough(let block) = decoded.kind else {
            Issue.record("Expected a sqlWalkthrough block")
            return
        }
        #expect(block.diffStyle == .split)
        #expect(block.envelope.afterSQL == "SELECT id FROM users")
        #expect(block.envelope.steps.count == 1)
    }

    @Test("A legacy text block without the walkthrough key still decodes")
    func legacyTextDecodes() throws {
        let json = Data(#"{"kind":"text","text":"hello"}"#.utf8)
        let decoded = try JSONDecoder().decode(ChatContentBlockWire.self, from: json)
        guard case .text(let value) = decoded.kind else {
            Issue.record("Expected a text block")
            return
        }
        #expect(value == "hello")
    }

    @Test("A walkthrough with a null afterSQL decodes as no diff")
    func explainStyleDecodes() throws {
        let block = SqlWalkthroughBlock(
            beforeSQL: "SELECT 1",
            envelope: SqlWalkthroughEnvelope(afterSQL: nil, steps: []),
            diffStyle: .unified
        )
        let wire = ChatContentBlockWire.sqlWalkthrough(block)
        let data = try JSONEncoder().encode(wire)
        let decoded = try JSONDecoder().decode(ChatContentBlockWire.self, from: data)
        guard case .sqlWalkthrough(let value) = decoded.kind else {
            Issue.record("Expected a sqlWalkthrough block")
            return
        }
        #expect(value.hasDiff == false)
    }
}

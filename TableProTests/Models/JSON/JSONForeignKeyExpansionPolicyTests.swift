//
//  JSONForeignKeyExpansionPolicyTests.swift
//  TableProTests
//
//  A self-referencing key must stop, and a long chain must stop too.
//

import Foundation
import Testing

@testable import TablePro

@Suite("JSONForeignKeyExpansionPolicy")
struct JSONForeignKeyExpansionPolicyTests {
    private func visit(_ table: String, _ value: String) -> JSONForeignKeyVisit {
        JSONForeignKeyVisit(table: table, schema: nil, column: "id", value: value)
    }

    @Test("A fresh key expands")
    func allowsFreshKeys() {
        #expect(
            JSONForeignKeyExpansionPolicy.decide(chain: [visit("film", "1")], next: visit("language", "1"))
                == .allowed
        )
    }

    @Test("The same row twice is a cycle")
    func stopsOnCycle() {
        let repeated = visit("employee", "7")
        #expect(
            JSONForeignKeyExpansionPolicy.decide(chain: [visit("employee", "9"), repeated], next: repeated)
                == .cycle
        )
    }

    @Test("The same table with a different row is not a cycle")
    func allowsSameTableDifferentRow() {
        #expect(
            JSONForeignKeyExpansionPolicy.decide(chain: [visit("employee", "7")], next: visit("employee", "8"))
                == .allowed
        )
    }

    @Test("A chain stops at the depth cap")
    func stopsAtDepthCap() {
        let chain = (0..<JSONForeignKeyExpansionPolicy.maxChainDepth).map { visit("t\($0)", "\($0)") }
        #expect(JSONForeignKeyExpansionPolicy.decide(chain: chain, next: visit("next", "1")) == .depthLimit)
        #expect(
            JSONForeignKeyExpansionPolicy.decide(chain: Array(chain.dropLast()), next: visit("next", "1"))
                == .allowed
        )
    }

    @Test("A cycle is reported before the depth cap, because it is the more useful answer")
    func reportsCycleBeforeDepth() {
        let chain = (0..<JSONForeignKeyExpansionPolicy.maxChainDepth).map { visit("t\($0)", "\($0)") }
        #expect(JSONForeignKeyExpansionPolicy.decide(chain: chain, next: chain[0]) == .cycle)
    }
}

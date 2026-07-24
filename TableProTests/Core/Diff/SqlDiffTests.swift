//
//  SqlDiffTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SqlDiff")
struct SqlDiffTests {
    @Test("computeSplit marks unchanged lines")
    func splitUnchanged() {
        let pairs = DiffComputer.computeSplit(before: ["a", "b"], after: ["a", "b"])
        #expect(pairs.count == 2)
        #expect(pairs.allSatisfy { $0.kind == .unchanged })
        #expect(pairs[0].before == "a")
        #expect(pairs[0].after == "a")
    }

    @Test("computeSplit detects a replaced line as changed")
    func splitChanged() {
        let pairs = DiffComputer.computeSplit(before: ["SELECT *"], after: ["SELECT id"])
        #expect(pairs.count == 1)
        #expect(pairs[0].kind == .changed)
        #expect(pairs[0].before == "SELECT *")
        #expect(pairs[0].after == "SELECT id")
    }

    @Test("computeSplit detects an added line")
    func splitAdded() {
        let pairs = DiffComputer.computeSplit(before: ["a"], after: ["a", "b"])
        #expect(pairs.contains(DiffPair(before: nil, after: "b", kind: .added)))
    }

    @Test("computeSplit detects a removed line")
    func splitRemoved() {
        let pairs = DiffComputer.computeSplit(before: ["a", "b"], after: ["a"])
        #expect(pairs.contains(DiffPair(before: "b", after: nil, kind: .removed)))
    }

    @Test("computeUnified splits a changed pair into a removed then added line")
    func unifiedChanged() {
        let lines = DiffComputer.computeUnified(before: ["SELECT *"], after: ["SELECT id"])
        #expect(lines.count == 2)
        #expect(lines[0].kind == .removed)
        #expect(lines[0].beforeLineNumber == 1)
        #expect(lines[0].afterLineNumber == nil)
        #expect(lines[1].kind == .added)
        #expect(lines[1].beforeLineNumber == nil)
        #expect(lines[1].afterLineNumber == 1)
    }

    @Test("computeUnified numbers context lines on both sides")
    func unifiedContext() {
        let lines = DiffComputer.computeUnified(before: ["a", "b"], after: ["a", "c"])
        let context = lines.first { $0.kind == .context }
        #expect(context?.beforeLineNumber == 1)
        #expect(context?.afterLineNumber == 1)
    }

    @Test("computeUnified assigns unique ids")
    func unifiedUniqueIds() {
        let lines = DiffComputer.computeUnified(before: ["a", "b", "c"], after: ["a", "x", "c"])
        let ids = lines.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("computeUnified from pairs matches computing it from the inputs")
    func unifiedFromPairsMatchesDirect() {
        let before = ["a", "b", "c", "d"]
        let after = ["a", "x", "d", "e"]
        let pairs = DiffComputer.computeSplit(before: before, after: after)

        #expect(DiffComputer.computeUnified(from: pairs) == DiffComputer.computeUnified(before: before, after: after))
    }

    @Test("computeUnified from pairs keeps ids unique across changed rows")
    func unifiedFromPairsKeepsIdsUnique() {
        let pairs = DiffComputer.computeSplit(before: ["a", "b"], after: ["x", "y"])
        let ids = DiffComputer.computeUnified(from: pairs).map(\.id)

        #expect(Set(ids).count == ids.count)
    }

    @Test("normalize collapses CRLF and trims boundary whitespace")
    func normalizeWhitespace() {
        #expect(SqlNormalizer.normalize("  SELECT 1\r\nFROM t  ") == "SELECT 1\nFROM t")
        #expect(SqlNormalizer.normalize("a\rb") == "a\nb")
    }

    @Test("lines on empty string yields one empty line")
    func linesEmpty() {
        #expect(SqlNormalizer.lines("") == [""])
    }

    @Test("lines preserves interior blank lines")
    func linesInterior() {
        #expect(SqlNormalizer.lines("a\n\nb") == ["a", "", "b"])
    }
}

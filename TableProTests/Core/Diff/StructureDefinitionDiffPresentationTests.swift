//
//  StructureDefinitionDiffPresentationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("StructureDefinitionDiffPresentation")
struct StructureDefinitionDiffPresentationTests {
    @Test("the target is the before side and the source is the after side")
    func targetIsBeforeAndSourceIsAfter() {
        let presentation = StructureDefinitionDiffPresentation(input: StructureDefinitionDiffInput(
            sourceLines: ["CREATE TABLE t (", "  id INT,", "  name TEXT", ")"],
            targetLines: ["CREATE TABLE t (", "  id BIGINT", ")"]
        ))

        #expect(presentation.pairs == [
            DiffPair(before: "CREATE TABLE t (", after: "CREATE TABLE t (", kind: .unchanged),
            DiffPair(before: "  id BIGINT", after: "  id INT,", kind: .changed),
            DiffPair(before: nil, after: "  name TEXT", kind: .added),
            DiffPair(before: ")", after: ")", kind: .unchanged)
        ])
    }

    @Test("a line only the target has is removed")
    func targetOnlyLineIsRemoved() {
        let presentation = StructureDefinitionDiffPresentation(input: StructureDefinitionDiffInput(
            sourceLines: ["a", "c"],
            targetLines: ["a", "b", "c"]
        ))

        #expect(presentation.pairs == [
            DiffPair(before: "a", after: "a", kind: .unchanged),
            DiffPair(before: "b", after: nil, kind: .removed),
            DiffPair(before: "c", after: "c", kind: .unchanged)
        ])
    }

    @Test("identical definitions pair every line as unchanged")
    func identicalDefinitionsAreUnchanged() {
        let lines = ["CREATE INDEX idx ON t (a)", "WHERE a > 0"]
        let presentation = StructureDefinitionDiffPresentation(input: StructureDefinitionDiffInput(
            sourceLines: lines,
            targetLines: lines
        ))

        #expect(presentation.pairs.allSatisfy { $0.kind == .unchanged })
        #expect(presentation.pairs.map(\.before) == lines)
        #expect(presentation.pairs.map(\.after) == lines)
    }

    @Test("two empty definitions have nothing to pair")
    func emptyDefinitionsHaveNoPairs() {
        let presentation = StructureDefinitionDiffPresentation(input: StructureDefinitionDiffInput(
            sourceLines: [],
            targetLines: []
        ))

        #expect(presentation.pairs.isEmpty)
    }

    @Test("loading builds the same presentation as computing it in place")
    func loadMatchesTheInPlacePresentation() async {
        let input = StructureDefinitionDiffInput(sourceLines: ["a", "b"], targetLines: ["a", "c"])

        let loaded = await StructureDefinitionDiffPresentation.load(input)

        #expect(loaded == StructureDefinitionDiffPresentation(input: input))
    }

    @Test("a presentation is current only for the definitions it was computed from")
    func presentationIsCurrentOnlyForItsInput() {
        let input = StructureDefinitionDiffInput(sourceLines: ["a"], targetLines: ["b"])
        let presentation = StructureDefinitionDiffPresentation(input: input)

        #expect(presentation.isCurrent(for: input))
        #expect(!presentation.isCurrent(for: StructureDefinitionDiffInput(sourceLines: ["a"], targetLines: ["c"])))
        #expect(!presentation.isCurrent(for: StructureDefinitionDiffInput(sourceLines: ["b"], targetLines: ["a"])))
    }
}

//
//  MarkdownInlineRepairTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Markdown inline repair for streaming tails")
struct MarkdownInlineRepairTests {
    private func repaired(_ source: String) -> String {
        MarkdownInlineRepair.repairingDanglingSyntax(source)
    }

    @Test("Settled text is never modified", arguments: [
        "plain sentence with no markers",
        "a **bold** run and an *italic* run",
        "a `code` span",
        "a [link](https://example.com) target",
        "nested **bold with `code` inside**",
        "escaped \\*not emphasis\\* stays literal",
        ""
    ])
    func settledTextIsUnchanged(source: String) {
        #expect(repaired(source) == source)
    }

    @Test("A dangling strong run is closed")
    func closesDanglingStrong() {
        #expect(repaired("this is **bold") == "this is **bold**")
    }

    @Test("Single asterisks are never speculatively closed", arguments: [
        "this is *italic",
        "COUNT(*) AS total",
        "the *.sql files",
        "run SELECT * FROM users",
        "a pointer int *p here",
        "lead *"
    ])
    func singleAsterisksAreLeftAlone(source: String) {
        #expect(repaired(source) == source)
    }

    @Test("A closed triple-asterisk span is left untouched")
    func tripleAsteriskSpanIsUntouched() {
        #expect(repaired("a ***bold italic*** run") == "a ***bold italic*** run")
        #expect(repaired("***bold italic***") == "***bold italic***")
    }

    @Test("A backslash inside a code span does not swallow the closing backtick")
    func backslashInsideCodeSpanDoesNotSwallowTheFence() {
        #expect(repaired("`a \\`") == "`a \\`")
        #expect(repaired("call `path\\` now") == "call `path\\` now")
    }

    @Test("A dangling code span is closed with a matching run")
    func closesDanglingCodeSpan() {
        #expect(repaired("call `SELECT id") == "call `SELECT id`")
    }

    @Test("A dangling link target is closed before the emphasis around it")
    func closesLinkTargetBeforeEmphasis() {
        #expect(repaired("**[text](htt") == "**[text](htt)**")
    }

    @Test("A lone asterisk followed by whitespace is left alone")
    func ignoresSelectStar() {
        #expect(repaired("run SELECT * FROM users") == "run SELECT * FROM users")
    }

    @Test("Underscores in identifiers are never treated as emphasis")
    func ignoresSnakeCaseIdentifiers() {
        #expect(repaired("the user_id and created_at columns") == "the user_id and created_at columns")
        #expect(repaired("a _leading underscore") == "a _leading underscore")
    }

    @Test("Markers inside a closed code span are not repaired")
    func ignoresMarkersInsideCodeSpan() {
        #expect(repaired("use `a ** b` here") == "use `a ** b` here")
    }

    @Test("An unclosed code span swallows later markers")
    func unclosedCodeSpanClosesOnlyItself() {
        #expect(repaired("use `a ** b") == "use `a ** b`")
    }

    @Test("Repair is stable when applied to its own output")
    func repairIsIdempotent() {
        let once = repaired("this is **bold")
        #expect(repaired(once) == once)
    }

    @Test("Growing any reply one character at a time never adds or loses prose", arguments: [
        "lead **bold text** tail",
        "a ***triple*** and `code` here",
        "SELECT COUNT(*) FROM t WHERE name LIKE '%a%'",
        "see [the docs](https://example.com) for **more**",
        "columns user_id, created_at and *.sql globs"
    ])
    func growingReplyNeverChangesProse(target: String) {
        let closerCharacters: Set<Character> = ["*", "`", ")"]
        let characters = Array(target)
        for length in 1...characters.count {
            let prefix = String(characters[0..<length])
            let result = repaired(prefix)
            #expect(
                result.filter { !closerCharacters.contains($0) }
                    == prefix.filter { !closerCharacters.contains($0) },
                "prose changed for prefix \(prefix) -> \(result)"
            )
        }
    }

    @Test("A trailing marker that cannot yet be classified is hidden, not shown raw")
    func trailingIncompleteMarkerIsHidden() {
        #expect(repaired("lead **") == "lead ")
        #expect(repaired("lead `") == "lead ")
    }

    @Test("Oversized input is returned untouched")
    func oversizedInputIsSkipped() {
        let huge = String(repeating: "a", count: 20_001) + "**bold"
        #expect(repaired(huge) == huge)
    }
}

//
//  RevealedTextTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
@testable import TablePro
import Testing

@Suite("Revealed text")
struct RevealedTextTests {
    @Test("A message with nothing invisible is left as it is")
    func ordinaryMessage() {
        let revealed = RevealedText("no such table: nope")
        #expect(revealed.segments == [.text("no such table: nope")])
        #expect(revealed.revealsAnyCharacter == false)
        #expect(revealed.plainText == "no such table: nope")
        #expect(revealed.spokenText == "no such table: nope")
    }

    @Test("An empty message has no segments")
    func emptyMessage() {
        let revealed = RevealedText("")
        #expect(revealed.segments.isEmpty)
        #expect(revealed.plainText.isEmpty)
    }

    @Test("The reported backspace between the quotes is named")
    func reportedBackspace() {
        let revealed = RevealedText("unrecognized token: \"\u{8}\"")
        #expect(revealed.segments == [
            .text("unrecognized token: \""),
            .marker(label: "BS", spokenName: "backspace"),
            .text("\"")
        ])
        #expect(revealed.revealsAnyCharacter)
        #expect(revealed.plainText == "unrecognized token: \"<BS>\"")
        #expect(revealed.spokenText == "unrecognized token: \" backspace \"")
    }

    @Test("A format character is labelled as the editor labels it and spoken by its Unicode name")
    func zeroWidthSpace() {
        let revealed = RevealedText("near \"SELECT\u{200B}Name\": syntax error")
        #expect(revealed.segments == [
            .text("near \"SELECT"),
            .marker(label: "ZWSP", spokenName: "zero width space"),
            .text("Name\": syntax error")
        ])
        #expect(revealed.plainText == "near \"SELECT<ZWSP>Name\": syntax error")
        #expect(revealed.spokenText == "near \"SELECT zero width space Name\": syntax error")
    }

    @Test("A special space keeps its width in plain text and is still spoken")
    func noBreakSpace() {
        let message = "near \"SELECT\u{A0}Name\": syntax error"
        let revealed = RevealedText(message)
        #expect(revealed.segments == [
            .text("near \"SELECT"),
            .blankSpace("\u{A0}", spokenName: "no-break space"),
            .text("Name\": syntax error")
        ])
        #expect(revealed.revealsAnyCharacter)
        #expect(revealed.plainText == message)
        #expect(revealed.spokenText == "near \"SELECT no-break space Name\": syntax error")
    }

    @Test("Tabs, line feeds and carriage returns are ordinary layout, not hidden characters")
    func preservedWhitespace() {
        let message = "ERROR:  syntax error\n\tLINE 1: SELECT\r\n"
        #expect(RevealedText(message).segments == [.text(message)])
    }

    @Test("A joiner inside an emoji sequence stays part of the emoji")
    func emojiJoiner() {
        let message = "invalid value \"👩\u{200D}💻\""
        #expect(RevealedText(message).revealsAnyCharacter == false)
    }

    @Test("Bidi controls cannot reorder the message they sit in")
    func bidiOverride() {
        let revealed = RevealedText("column \"a\u{202E}b\" does not exist")
        #expect(revealed.plainText == "column \"a<RLO>b\" does not exist")
    }

    @Test("A character outside the Basic Multilingual Plane is revealed whole")
    func supplementaryCharacter() {
        let revealed = RevealedText("tag\u{E0001}here")
        #expect(revealed.segments == [
            .text("tag"),
            .marker(label: "E0001", spokenName: "language tag"),
            .text("here")
        ])
    }

    @Test("Neighbouring hidden characters are each revealed")
    func adjacentCharacters() {
        let revealed = RevealedText("\u{0}\u{0}\u{FEFF}")
        #expect(revealed.plainText == "<NUL><NUL><BOM>")
        #expect(revealed.segments.count == 3)
    }

    @Test("The styled text shows each label in the mark colour and tints a special space")
    func styledRuns() {
        let styled = RevealedText("a\u{8}b\u{A0}c").styledText
        #expect(String(styled.characters) == "a<BS>b\u{A0}c")

        let runs = styled.runs.map { run in
            (String(styled[run.range].characters), run.foregroundColor, run.backgroundColor)
        }
        #expect(runs.count == 5)
        #expect(runs[0].0 == "a" && runs[0].1 == nil && runs[0].2 == nil)
        #expect(runs[1].0 == "<BS>" && runs[1].1 == RevealedText.markColor && runs[1].2 == RevealedText.markBackground)
        #expect(runs[2].0 == "b" && runs[2].1 == nil && runs[2].2 == nil)
        #expect(runs[3].0 == "\u{A0}" && runs[3].1 == nil && runs[3].2 == RevealedText.blankSpaceBackground)
        #expect(runs[4].0 == "c" && runs[4].1 == nil && runs[4].2 == nil)
    }

    @Test("A selection copied from a marked message reads as the error alert shows it")
    func styledCharactersMatchPlainText() {
        let messages = [
            "unrecognized token: \"\u{8}\"",
            "near \"SELECT\u{A0}1\u{200B}\u{1B}\": syntax error",
            "tag\u{E0001}here\u{0}"
        ]
        for message in messages {
            let revealed = RevealedText(message)
            #expect(String(revealed.styledText.characters) == revealed.plainText)
        }
    }
}

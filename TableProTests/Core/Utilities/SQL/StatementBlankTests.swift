//
//  StatementBlankTests.swift
//  TableProTests
//

import CodeEditTextView
import Foundation
@testable import TablePro
import Testing

@Suite("Statement blank characters")
struct StatementBlankTests {
    private static func label(_ value: UInt32) -> String {
        String(format: "U+%04X", value)
    }

    @Test("Everything the run path used to trim as whitespace is still blank")
    func coversEveryEarlierWhitespaceDefinition() {
        for value in UInt32(0)...0xFFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let wasWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar.properties.isWhitespace
                || value == UInt32(SqlLexer.space)
                || value == UInt32(SqlLexer.tab)
            guard wasWhitespace else { continue }
            #expect(StatementBlank.isBlank(scalar), "\(Self.label(value))")
        }
    }

    @Test("Every character the editor reveals is blank unless it is a letter")
    func coversEveryCharacterTheEditorMarks() {
        let supplementary: [ClosedRange<UInt32>] = [0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0000...0xE01EF]
        let basic = (UInt32(0)...0xFFFF).filter { SpecialCharacter.mayBeSpecial(UInt16($0)) }
        var marked = 0
        for value in basic + supplementary.flatMap({ Array($0) }) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = String(Character(scalar)) as NSString
            guard SpecialCharacter.classify(in: text, at: 0) != nil else { continue }
            marked += 1
            #expect(StatementBlank.isBlank(scalar) == !scalar.properties.isAlphabetic, "\(Self.label(value))")
        }
        #expect(marked > 100)
    }

    @Test("A filler that is a letter is content", arguments: [0x115F, 0x1160, 0x3164, 0xFFA0] as [UInt32])
    func letterFillersAreContent(value: UInt32) throws {
        let scalar = try #require(Unicode.Scalar(value))
        #expect(!StatementBlank.isBlank(scalar))
    }

    @Test("Visible text is content")
    func visibleTextIsContent() {
        for scalar in "SELECT;()'\"`-_0#$@éß中😀".unicodeScalars {
            #expect(!StatementBlank.isBlank(scalar), "\(Self.label(scalar.value))")
        }
    }

    @Test(
        "A character is blank only when every scalar in it is",
        arguments: [
            ("\r\n", true),
            ("\u{00A0}\u{200D}", true),
            ("\u{FE0F}", true),
            ("\u{00A0}\u{0301}", false),
            ("\u{2764}\u{FE0F}", false),
            ("1\u{E0020}", false),
        ] as [(String, Bool)]
    )
    func characterIsBlankOnlyWhenEveryScalarIs(text: String, isBlank: Bool) throws {
        #expect(text.count == 1)
        let character = try #require(text.first)
        #expect(StatementBlank.isBlank(character) == isBlank)
    }

    @Test("A blank outside the BMP is measured as the two units it occupies")
    func supplementaryBlankLength() {
        let text = "\u{E0020}x" as NSString
        #expect(StatementBlank.blankLength(in: text, at: 0) == 2)
        #expect(StatementBlank.blankLength(in: text, at: 2) == 0)
    }

    @Test("Half of a surrogate pair is never blank")
    func halfOfASurrogatePairIsNotBlank() {
        let text = "\u{E0020}" as NSString
        #expect(StatementBlank.blankLength(in: text, at: 1) == 0)
    }

    @Test("Every ASCII character is blank exactly when it is a space or a control character")
    func asciiBlanksAreSpaceAndControls() throws {
        for value in UInt32(0)...0x7F {
            let scalar = try #require(Unicode.Scalar(value))
            let expected = scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
            #expect(StatementBlank.isBlank(scalar) == expected, "\(Self.label(value))")
        }
    }

    @Test("Offsets outside the text measure nothing")
    func offsetsOutsideTheText() {
        let text = " " as NSString
        #expect(StatementBlank.blankLength(in: text, at: -1) == 0)
        #expect(StatementBlank.blankLength(in: text, at: 1) == 0)
    }

    @Test("Trimming takes blanks off both ends and leaves the inside alone")
    func trimsBothEnds() {
        let text = "\u{FEFF}\u{0008}\u{00A0} SEL\u{200B}ECT 1 \u{3000}\u{E0020}\u{2028}"
        #expect(StatementBlank.trimming(text) == "SEL\u{200B}ECT 1")
    }

    @Test("Text made only of blanks trims to nothing")
    func allBlankTrimsToNothing() {
        #expect(StatementBlank.trimming(" \u{00A0}\u{200B}\u{FEFF}\u{0008}\u{3000}\u{E0020}").isEmpty)
    }

    @Test(
        "An invisible character attached to the last visible one stays with it",
        arguments: [
            "SET k \u{2764}\u{FE0F}",
            "SET flag \u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
            "SET k \u{0915}\u{094D}\u{200D}",
            "SET k \u{0645}\u{06CC}\u{200C}",
            "SELECT 1\u{E0020}",
        ]
    )
    func attachedInvisibleCharacterIsKept(text: String) {
        #expect(StatementBlank.trimming(text) == text)
        #expect(StatementBlank.trimming("\u{FEFF}" + text + "\u{0008}\n") == text)
    }

    @Test("A visible mark on a blank character makes it content")
    func markOnABlankIsContent() {
        let text = "\u{00A0}\u{0301}SELECT 1"
        #expect(StatementBlank.trimming(text) == text)
    }

    @Test("Trimming a substring stays inside it")
    func trimmingRespectsTheSubstring() {
        let text = "x \u{00A0}SELECT 1\u{00A0} x"
        let inner = text.dropFirst().dropLast()
        #expect(StatementBlank.trimming(inner) == "SELECT 1")
    }

    @Test(
        "The content range is the trimmed text measured in UTF-16 units",
        arguments: [
            ("\u{FEFF}\u{E0020} SELECT 1\u{00A0}\n", NSRange(location: 4, length: 8)),
            ("\u{1F600} \u{2764}\u{FE0F}\u{200B}", NSRange(location: 0, length: 5)),
            ("\u{00A0}\u{200B}", NSRange(location: 2, length: 0)),
        ] as [(String, NSRange)]
    )
    func contentRangeIsMeasuredInUTF16(text: String, expected: NSRange) {
        let range = StatementBlank.contentRange(of: text)
        #expect(range == expected)
        #expect((text as NSString).substring(with: range) == StatementBlank.trimming(text))
    }

    @Test("Text holds content when any character in it is visible")
    func hasContent() {
        #expect(StatementBlank.hasContent("\u{FEFF} x"))
        #expect(StatementBlank.hasContent("\u{00A0}\u{0301}"))
        #expect(!StatementBlank.hasContent("\u{FEFF}\u{0008}\u{200B} \n\u{E0020}"))
        #expect(!StatementBlank.hasContent(""))
    }

    @Test("Leading blanks come off a substring and nothing after the first visible character does")
    func trimmingLeadingStopsAtContent() {
        let text = "\u{0008}\u{FEFF} \u{E0020}SEL\u{200B}ECT 1"
        #expect(StatementBlank.trimmingLeading(text[...]) == "SEL\u{200B}ECT 1")
    }

    @Test("Leading trimming keeps a visible mark on a blank character")
    func trimmingLeadingKeepsAMarkedBlank() {
        let text = "\u{3000}\u{0301}SELECT"
        #expect(StatementBlank.trimmingLeading(text[...]) == text[...])
    }
}

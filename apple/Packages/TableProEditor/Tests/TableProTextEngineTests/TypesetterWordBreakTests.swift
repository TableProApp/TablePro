import AppKit
import Foundation
@testable import TableProTextEngine
import Testing

@MainActor
@Suite("Typesetter word breaks")
struct TypesetterWordBreakTests {
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    ]

    // The text of each wrapped fragment when a line is `columns` characters wide.
    private func fragments(_ text: String, columns: Int) -> [String] {
        let characterWidth = ("x" as NSString).size(withAttributes: Self.attributes).width
        let length = (text as NSString).length
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: text, attributes: Self.attributes),
            documentRange: NSRange(location: 0, length: length),
            displayData: TextLine.DisplayData(
                maxWidth: CGFloat(columns) * characterWidth + 0.5,
                lineHeightMultiplier: 1.0,
                estimatedLineHeight: 20.0,
                breakStrategy: .word
            ),
            markedRanges: nil,
            attachments: []
        )
        var texts: [String] = []
        for fragment in typesetter.lineFragments {
            texts.append((text as NSString).substring(with: fragment.range))
        }
        return texts
    }

    @Test("A quoted identifier is never split at a quote or an underscore")
    func quotedIdentifiersStayWhole() {
        let constraint = #"ALTER TABLE "public"."reviews" ADD CONSTRAINT "reviews_rating_check" CHECK ((rating >= 1) AND (rating <= 5));"#
        #expect(fragments(constraint, columns: 30) == [
            #"ALTER TABLE "public"."reviews" "#,
            "ADD CONSTRAINT ",
            #""reviews_rating_check" CHECK "#,
            "((rating >= 1) AND (rating <= ",
            "5));"
        ])

        let index = #"CREATE INDEX "idx_reviews_product_id" ON "public"."reviews" ("product_id");"#
        #expect(fragments(index, columns: 30) == [
            "CREATE INDEX ",
            #""idx_reviews_product_id" ON "#,
            #""public"."reviews" "#,
            #"("product_id");"#
        ])
    }

    @Test("A space at the edge stays on the line it ends")
    func spaceAtTheEdgeHangs() {
        #expect(fragments("abcdefghij klmnopqrst", columns: 10) == ["abcdefghij ", "klmnopqrst"])
    }

    @Test("A run with nowhere to break still breaks after punctuation")
    func unbreakableRunBreaksAfterPunctuation() {
        let identifier = "select_very_long_identifier_without_any_spaces_at_all_that_exceeds_the_width_of_the_line_for_sure"
        #expect(fragments(identifier, columns: 30) == [
            "select_very_long_identifier_",
            "without_any_spaces_at_all_",
            "that_exceeds_the_width_of_the_",
            "line_for_sure"
        ])
    }

    @Test("Text that allows a break between any two characters fills the line")
    func ideographsFillTheLine() {
        let text = "日本語。テキストを折り返すテストです"
        let wrapped = fragments(text, columns: 10)

        #expect(wrapped.joined() == text)
        #expect((wrapped.first?.count ?? 0) > "日本語。".count)
    }

    @Test("A run with no punctuation in reach breaks at the edge")
    func unbreakableRunBreaksAtTheEdge() {
        let run = String(repeating: "a", count: 300)
        #expect(fragments(run, columns: 120).map { $0.count } == [120, 120, 60])
    }

    @Test("Punctuation 99 characters back from the edge is in reach, 100 back is not")
    func punctuationSearchReachesBack99Characters() {
        func run(underscoreAt offset: Int) -> String {
            var characters = Array(repeating: "a", count: 300)
            characters[offset] = "_"
            return characters.joined()
        }

        #expect(fragments(run(underscoreAt: 21), columns: 120).first?.count == 22)
        #expect(fragments(run(underscoreAt: 20), columns: 120).first?.count == 120)
    }

    // The search walks back from the edge to one past the fragment's start, which here is the low surrogate.
    @Test("Supplementary punctuation whose low surrogate is the last offset searched still breaks after it")
    func supplementaryPunctuationAtTheSearchsEnd() {
        let text = "\u{1E95E}" + String(repeating: "a", count: 200)
        #expect(fragments(text, columns: 30).first == "\u{1E95E}")
    }

    @Test("The break test answers what the composed-sequence rule answers, at every offset of 2,000 strings")
    func breakTestMatchesTheComposedSequenceRule() {
        var generator = SplitMix64(seed: 0x5EED_1E55)
        var mismatches: [String] = []
        for _ in 0..<2_000 {
            let text = Self.generatedText(using: &generator)
            let reference = NSAttributedString(string: text as String)
            for index in 0..<text.length
            where LineBreakCharacters.canBreakLine(at: index, in: text) != Self.referenceCanBreak(at: index, for: reference) {
                mismatches.append("break at \(index) of \((text as String).debugDescription)")
            }
            for index in 0...text.length
            where LineBreakCharacters.isCRLF(endingAt: index, in: text) != Self.referenceIsCRLF(index, for: reference) {
                mismatches.append("CRLF at \(index) of \((text as String).debugDescription)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
    }

    // The helpers as they were before the break test stopped building character sets.
    private static func referenceCanBreak(at index: Int, for string: NSAttributedString) -> Bool {
        let subrange = (string.string as NSString).rangeOfComposedCharacterSequence(at: index)
        let set = CharacterSet(charactersIn: (string.string as NSString).substring(with: subrange))
        return set.isSubset(of: .whitespacesAndNewlines) || set.isSubset(of: .punctuationCharacters)
    }

    private static func referenceIsCRLF(_ breakIndex: Int, for string: NSAttributedString) -> Bool {
        guard breakIndex - 1 > 0 && breakIndex + 1 <= string.length else {
            return false
        }
        return string.attributedSubstring(from: NSRange(location: breakIndex - 1, length: 2)).string == "\r\n"
    }

    private static let pieces: [[unichar]] = {
        let strings = [
            "a", "Z", "x9", "0", "_", ".", ",", "-", "(", ")", "\"", "'", "/", ":", ";", "!", "?", "#", "%", "&", "*", "@",
            "[", "]", "{", "}", "\\", "$", "+", "<", "=", ">", "^", "`", "|", "~",
            " ", "\t", "\n", "\r", "\r\n", "\u{00A0}", "\u{3000}", "\u{200B}", "\u{2028}", "\u{0085}",
            ".\u{0301}", ",\u{20DD}", "_\u{0308}", " \u{0301}", "\u{0301}", "\u{0600}1", "\u{0600}.",
            "😀", "👩‍💻", "👍🏽", "🇻🇳", "1\u{FE0F}\u{20E3}", "日本", "。", "、", "「", "」", "ー", "\u{1100}\u{1161}",
            "\u{10100}", "\u{1039F}", "\u{1E95E}", "\u{12470}", "\u{1D400}", "\u{20000}",
        ]
        return strings.map { Array($0.utf16) } + [[0xD800], [0xDC00], [0xDBFF, 0x41], [0x2E, 0xDC00]]
    }()

    private static func generatedText(using generator: inout SplitMix64) -> NSString {
        var units: [unichar] = []
        let count = Int.random(in: 1...24, using: &generator)
        for _ in 0..<count {
            units += pieces.randomElement(using: &generator) ?? []
        }
        return NSString(characters: units, length: units.count)
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

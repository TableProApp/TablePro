//
//  TypesetterWrapLengthTests.swift
//  TableProTests
//
//  Regression tests for wrapped line typesetting. `suggestLineBreak` returns an offset into the run,
//  not a length, but the typesetter passed it straight through as the CTLine length. Every fragment
//  after the first then re-typeset all the text before it, so glyph work and retained memory grew
//  with the square of the line length and a long single line could exhaust memory.
//
//  These live here rather than in CodeEditTextViewTests because the TablePro scheme does not run
//  that package's test target, so a test there would never gate a regression.
//

import AppKit
@testable import CodeEditTextView
import Foundation
import Testing

@MainActor
@Suite("Typesetter wrapped fragment lengths")
struct TypesetterWrapLengthTests {
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    ]

    private func typesetWrapped(characterCount: Int, maxWidth: CGFloat) -> Typesetter {
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: String(repeating: "A", count: characterCount), attributes: Self.attributes),
            documentRange: NSRange(location: 0, length: characterCount),
            displayData: TextLine.DisplayData(
                maxWidth: maxWidth,
                lineHeightMultiplier: 1.0,
                estimatedLineHeight: 20.0,
                breakStrategy: .character
            ),
            markedRanges: nil,
            attachments: []
        )
        return typesetter
    }

    @Test("A wrapped line typesets each character exactly once")
    func wrappedLineTypesetsEachCharacterOnce() {
        let characterCount = 1_000
        let typesetter = typesetWrapped(characterCount: characterCount, maxWidth: 150)

        var typesetCharacters = 0
        for fragment in typesetter.lineFragments {
            typesetCharacters += fragment.data.contents.reduce(0) { $0 + $1.length }
        }

        #expect(
            typesetCharacters == characterCount,
            "Each character must be typeset once, not once per following fragment"
        )
    }

    @Test("Each wrapped fragment typesets exactly the characters it covers")
    func eachFragmentTypesetsOnlyItsOwnCharacters() {
        let typesetter = typesetWrapped(characterCount: 1_000, maxWidth: 150)

        for fragment in typesetter.lineFragments {
            let typesetLength = fragment.data.contents.reduce(0) { $0 + $1.length }
            #expect(
                typesetLength == fragment.range.length,
                "A fragment covering \(fragment.range.length) characters typeset \(typesetLength)"
            )
        }
    }

    @Test("Wrapping stays linear as the line grows")
    func wrappingStaysLinearAsTheLineGrows() {
        let small = typesetWrapped(characterCount: 1_000, maxWidth: 150)
        let large = typesetWrapped(characterCount: 4_000, maxWidth: 150)

        func typesetCharacters(in typesetter: Typesetter) -> Int {
            var total = 0
            for fragment in typesetter.lineFragments {
                total += fragment.data.contents.reduce(0) { $0 + $1.length }
            }
            return total
        }

        // Four times the text must cost four times the typesetting, not sixteen.
        #expect(typesetCharacters(in: large) == typesetCharacters(in: small) * 4)
    }
}

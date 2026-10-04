//
//  TypesetterWordBreakTests.swift
//  TableProTextEngineTests
//

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

    /// The text of each wrapped fragment when a line is `columns` characters wide.
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
}

//
//  HighlighterRestyleTests.swift
//  TableProEditorKit
//

import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

/// A theme change moves no capture. Styling the captures already found keeps the text styled, where asking the
/// providers again left it plain until they answered.
@MainActor
struct HighlighterRestyleTests {
    private final class SwitchableAttributes: ThemeAttributesProviding {
        var keywordColor: NSColor = .systemRed

        func attributesFor(_ capture: CaptureName?) -> [NSAttributedString.Key: Any] {
            capture == .keyword ? [.foregroundColor: keywordColor] : [:]
        }
    }

    @Test("Restyling applies the new colors to the captures already found without asking the providers again")
    func restyleReusesCaptures() {
        let provider = HighlighterTests.MockHighlightProvider {
            .success([HighlightRange(range: NSRange(location: 0, length: 6), capture: .keyword)])
        }
        let attributes = SwitchableAttributes()
        let textView = Mock.textView()
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        textView.setText("SELECT 1")
        let highlighter = Mock.highlighter(
            textView: textView,
            highlightProviders: [provider],
            attributeProvider: attributes
        )
        highlighter.invalidate()
        #expect(color(at: 0, in: textView) == .systemRed)
        let queries = provider.queryCount

        attributes.keywordColor = .systemBlue
        highlighter.restyle()

        #expect(color(at: 0, in: textView) == .systemBlue)
        #expect(provider.queryCount == queries)
    }

    private func color(at location: Int, in textView: TextView) -> NSColor? {
        textView.textStorage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }
}

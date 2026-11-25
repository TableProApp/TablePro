import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct HighlighterLengthLimitTests {
    private final class KeywordAttributes: ThemeAttributesProviding {
        var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        func attributesFor(_ capture: CaptureName?) -> [NSAttributedString.Key: Any] {
            [.foregroundColor: capture == .keyword ? NSColor.systemRed : NSColor.textColor, .font: font]
        }
    }

    private let attributes = KeywordAttributes()

    private func keywordProvider() -> HighlighterTests.MockHighlightProvider {
        HighlighterTests.MockHighlightProvider {
            .success([HighlightRange(range: NSRange(location: 0, length: 6), capture: .keyword)])
        }
    }

    private func makeHighlighter(
        _ text: String,
        limit: Int,
        provider: HighlighterTests.MockHighlightProvider
    ) -> (TextView, Highlighter) {
        let textView = Mock.textView()
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        textView.setText(text)
        let highlighter = Mock.highlighter(
            textView: textView,
            highlightProviders: [provider],
            attributeProvider: attributes,
            maxHighlightableLength: limit
        )
        return (textView, highlighter)
    }

    private func color(at location: Int, in textView: TextView) -> NSColor? {
        textView.textStorage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    @Test("A document at the limit is highlighted")
    func highlightsAtTheLimit() {
        let provider = keywordProvider()
        let (textView, highlighter) = makeHighlighter("SELECT 1", limit: 8, provider: provider)

        highlighter.invalidate()

        #expect(color(at: 0, in: textView) == .systemRed)
    }

    @Test("An edit past the limit leaves the whole document plain")
    func editPastTheLimitRemovesTheColors() {
        let provider = keywordProvider()
        let (textView, highlighter) = makeHighlighter("SELECT 1", limit: 8, provider: provider)
        highlighter.invalidate()

        withExtendedLifetime(highlighter) {
            textView.replaceCharacters(in: NSRange(location: 8, length: 0), with: ";")
        }

        #expect(color(at: 0, in: textView) == .textColor)
        #expect(provider.editCount == 0)
    }

    @Test("Back under the limit, the providers start over from the text")
    func editBackUnderTheLimitSetsTheProvidersUpAgain() {
        let provider = keywordProvider()
        let (textView, highlighter) = makeHighlighter("SELECT 1", limit: 8, provider: provider)
        let setUps = provider.setUpCount

        withExtendedLifetime(highlighter) {
            textView.replaceCharacters(in: NSRange(location: 8, length: 0), with: "0")
            textView.replaceCharacters(in: NSRange(location: 8, length: 1), with: "")
        }

        #expect(provider.editCount == 0)
        #expect(provider.setUpCount == setUps + 1)
        #expect(color(at: 0, in: textView) == .systemRed)
    }

    @Test("A font change reaches a document over the limit without a query")
    func fontChangeOverTheLimitRestylesThePlainText() {
        let provider = keywordProvider()
        let (textView, highlighter) = makeHighlighter("SELECT 1", limit: 4, provider: provider)

        attributes.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        highlighter.invalidate()

        #expect(textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == attributes.font)
        #expect(provider.queryCount == 0)
    }

    @Test("A document that opens over the limit is set up only once it comes under it")
    func documentOverTheLimitIsNotSetUp() {
        let provider = keywordProvider()
        let (textView, highlighter) = makeHighlighter("SELECT 1", limit: 6, provider: provider)

        highlighter.invalidate()

        #expect(provider.setUpCount == 0)
        #expect(provider.queryCount == 0)
        #expect(color(at: 0, in: textView) != .systemRed)

        withExtendedLifetime(highlighter) {
            textView.replaceCharacters(in: NSRange(location: 6, length: 2), with: "")
        }

        #expect(provider.setUpCount == 1)
        #expect(color(at: 0, in: textView) == .systemRed)
    }
}

import AppKit
@testable import TablePro
import Testing

@MainActor
struct FormatterPreviewTests {
    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private static func options(_ change: (inout SQLFormatterOptions) -> Void) -> SQLFormatterOptions {
        var options = SQLFormatterOptions.default
        change(&options)
        return options
    }

    @Test("The same options and font compare equal, so a re-render skips the format")
    func equalInputsSkipTheBody() {
        let first = FormatterPreview(options: .default, font: Self.font)
        let second = FormatterPreview(options: .default, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        #expect(first == second)
    }

    @Test("A rule or font change formats again")
    func changedInputsRender() {
        let base = FormatterPreview(options: .default, font: Self.font)
        let wider = FormatterPreview(options: Self.options { $0.lineWidth = 120 }, font: Self.font)
        let larger = FormatterPreview(options: .default, font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular))
        #expect(base != wider)
        #expect(base != larger)
    }

    @Test("The sample follows the rules it is given")
    func sampleFollowsTheRules() {
        let upper = FormatterPreview.formattedSample(options: Self.options { $0.keywordCase = .upper })
        let lower = FormatterPreview.formattedSample(options: Self.options { $0.keywordCase = .lower })
        #expect(upper.hasPrefix("SELECT"))
        #expect(lower.hasPrefix("select"))

        let onePerLine = FormatterPreview.formattedSample(options: Self.options { $0.lineWidth = 0 })
        let wide = FormatterPreview.formattedSample(options: Self.options { $0.lineWidth = 120 })
        #expect(FormatterPreview.lineCount(of: wide) < FormatterPreview.lineCount(of: onePerLine))
    }

    @Test("The preview grows with its lines up to twelve, plus the inset")
    func heightStopsAtTwelveLines() {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Self.font)
        let chrome = FormatterPreview.chromeHeight
        #expect(FormatterPreview.height(lineCount: 3, font: Self.font) == 3 * lineHeight + chrome)
        #expect(FormatterPreview.height(lineCount: 30, font: Self.font) == 12 * lineHeight + chrome)
        #expect(FormatterPreview.height(lineCount: 0, font: Self.font) == lineHeight + chrome)
    }
}

@MainActor
struct SQLFormattingChoiceTests {
    @Test("A line width off the list is offered after the list; One item per line is never an extra")
    func lineWidthOptions() {
        #expect(SQLFormattingPage.lineWidthOptions(including: 60).extra == 60)
        #expect(SQLFormattingPage.lineWidthOptions(including: 60).fixed == [80, 100, 120])
        #expect(SQLFormattingPage.lineWidthOptions(including: 0).extra == nil)
        #expect(SQLFormattingPage.lineWidthOptions(including: 100).extra == nil)
    }

    @Test("An imported indent width off the list stays selectable")
    func indentWidthOptions() {
        let options = SettingsChoices.options(SQLFormattingPage.indentWidths, including: 3)
        #expect(options.fixed == [2, 4, 8])
        #expect(options.extra == 3)
    }

    @Test("Picking a fixed indent width turns off following the editor and sets the width in one write")
    func indentWidthChoiceWritesWholeValue() {
        var following = SQLFormatterSettings.default
        following.indentFollowsTabWidth = true
        #expect(SQLFormattingPage.IndentWidthChoice(following) == .editor)

        let fixed = SQLFormattingPage.IndentWidthChoice.fixed(8).applied(to: following)
        #expect(!fixed.indentFollowsTabWidth)
        #expect(fixed.rules.indentWidth == 8)
        #expect(SQLFormattingPage.IndentWidthChoice(fixed) == .fixed(8))

        let back = SQLFormattingPage.IndentWidthChoice.editor.applied(to: fixed)
        #expect(back.indentFollowsTabWidth)
        #expect(back.rules.indentWidth == 8)
    }

    @Test("Picking a fixed keyword case turns off following the editor and sets the case in one write")
    func keywordCaseChoiceWritesWholeValue() {
        let following = SQLFormatterSettings.default
        #expect(SQLFormattingPage.KeywordCaseChoice(following) == .editor)

        let lower = SQLFormattingPage.KeywordCaseChoice.fixed(.lower).applied(to: following)
        #expect(!lower.keywordCaseFollowsEditor)
        #expect(lower.rules.keywordCase == .lower)

        let back = SQLFormattingPage.KeywordCaseChoice.editor.applied(to: lower)
        #expect(back.keywordCaseFollowsEditor)
        #expect(back.rules.keywordCase == .lower)
    }
}

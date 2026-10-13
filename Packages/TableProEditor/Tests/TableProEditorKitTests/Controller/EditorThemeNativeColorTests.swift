//
//  EditorThemeNativeColorTests.swift
//  TableProEditorKit
//

import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

/// A theme that overrides nothing hands the editor system colors. The editor has to draw them the way AppKit does,
/// resolved for the appearance it draws in, never frozen at the appearance current when the theme was applied.
@MainActor
struct EditorThemeNativeColorTests {
    @Test("Line numbers, run controls and fold chevrons default to the secondary label color")
    func gutterDefaultsToSecondaryLabel() {
        let controller = Mock.loadedTextViewController()

        #expect(controller.gutterView.textColor == .secondaryLabelColor)
        #expect(controller.gutterView.statementRunRibbon.glyphColor == .secondaryLabelColor)
        #expect(controller.gutterView.foldingRibbon.chevronColor == .secondaryLabelColor)
    }

    @Test("The run control under the pointer keeps the accent color")
    func hoveredRunControlFollowsAccent() {
        let controller = Mock.loadedTextViewController()

        #expect(controller.gutterView.statementRunRibbon.hoveredGlyphColor == .controlAccentColor)
    }

    @Test("A theme's line number color reaches every gutter control")
    func lineNumberOverrideReachesTheGutter() {
        let controller = Mock.loadedTextViewController()
        var theme = controller.theme
        theme.lineNumber = .systemPurple

        controller.configuration.appearance.theme = theme

        #expect(controller.gutterView.textColor == .systemPurple)
        #expect(controller.gutterView.statementRunRibbon.glyphColor == .systemPurple)
        #expect(controller.gutterView.foldingRibbon.chevronColor == .systemPurple)
    }

    @Test("Tints derived from the text color resolve again in each appearance")
    func derivedTintsStayDynamic() throws {
        let controller = Mock.loadedTextViewController()
        let ribbon = controller.gutterView.foldingRibbon

        let light = try components(of: ribbon.collapsedChevronColor, in: .aqua)
        let dark = try components(of: ribbon.collapsedChevronColor, in: .darkAqua)

        #expect(light.red < 0.1 && abs(light.alpha - 0.65) < 0.01, "Aqua: \(light)")
        #expect(dark.red > 0.9 && abs(dark.alpha - 0.65) < 0.01, "DarkAqua: \(dark)")
    }

    @Test("The text view paints the theme background itself, the way NSTextView draws its background")
    func textViewPaintsTheThemeBackground() throws {
        let controller = Mock.loadedTextViewController()
        let textView = try #require(controller.textView as? SourceEditorTextView)

        #expect(textView.backgroundFillColor == controller.theme.background)

        var theme = controller.theme
        theme.background = .systemTeal
        controller.configuration.appearance.theme = theme
        #expect(textView.backgroundFillColor == .systemTeal)

        controller.configuration.appearance.useThemeBackground = false
        #expect(textView.backgroundFillColor == nil)
    }

    @Test("A theme without a cursor color leaves the caret to the system")
    func caretIsNativeUnlessOverridden() {
        let controller = Mock.loadedTextViewController()
        #expect(controller.textView.selectionManager.insertionPointColor == nil)

        var theme = controller.theme
        theme.insertionPoint = .systemPink
        controller.configuration.appearance.theme = theme
        #expect(controller.textView.selectionManager.insertionPointColor == .systemPink)

        theme.insertionPoint = nil
        controller.configuration.appearance.theme = theme
        #expect(controller.textView.selectionManager.insertionPointColor == nil)
    }

    /// An Accent or Highlight change rebuilds the theme from the same system color objects. Equal themes are what
    /// keep that from restyling the document and dropping every measured line width.
    @Test("A theme rebuilt from the same system colors leaves the laid out document alone")
    func equalSystemColorThemeIsANoOp() {
        let (window, controller) = Mock.windowedTextViewController(theme: Mock.theme())
        defer { window.close() }
        controller.configuration.appearance.wrapLines = false
        controller.reloadUI()
        window.layoutIfNeeded()
        controller.textView.string = String(repeating: "SELECT 1 ", count: 80)
        controller.textView.updateFrameIfNeeded()
        controller.textView.layoutManager.layoutLines()
        let width = controller.textView.layoutManager.lineStorage.maxWidth
        #expect(width > 0)

        controller.configuration.appearance.theme = Mock.theme()

        #expect(controller.textView.layoutManager.lineStorage.maxWidth == width)
    }

    private func components(
        of color: NSColor,
        in name: NSAppearance.Name
    ) throws -> (red: CGFloat, alpha: CGFloat) {
        let appearance = try #require(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        let srgb = try #require(resolved)
        return (srgb.redComponent, srgb.alphaComponent)
    }
}

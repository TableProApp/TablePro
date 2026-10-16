//
//  HighlightedSQLTextView.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProEditorKit
import TableProGrammars
import TableProPluginKit
import TableProTheme

/// A code view: `ThemeTextViewStyle` puts it on the editor's background, text, caret and selection, and its
/// syntax comes from the editor's own grammar and `EditorTheme`, so every token draws in the slot the SQL
/// editor gives it.
struct HighlightedSQLTextView: NSViewRepresentable {
    internal enum LineLayout: Equatable {
        case unwrapped
        case wrapped
        /// Wraps, and is as tall as its text up to `maxLines`; it scrolls vertically past that.
        case fitted(maxLines: Int)
    }

    internal enum Highlighting: Equatable {
        case engine
        case json
    }

    let sql: String
    var databaseType: DatabaseType = .mysql
    var highlighting: Highlighting = .engine
    /// A SwiftUI `.accessibilityIdentifier` lands on the representable's wrapper, not on the text
    /// view AppKit publishes, so the only way to name this element is to set it on the text view.
    var accessibilityIdentifier: String?
    var lineLayout: LineLayout = .unwrapped

    @ObservedObject private var themeEngine = ThemeEngine.shared

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(String(localized: "Query preview"))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = themeEngine.editorFonts.font
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        applyLineLayout(to: scrollView, textView: textView)

        context.coordinator.attach(to: scrollView, textView: textView)
        return scrollView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard case .fitted(let maxLines) = lineLayout,
              let width = proposal.width, width.isFinite,
              let textView = scrollView.documentView as? NSTextView else { return nil }
        let height = Self.fittedHeight(
            of: sql,
            font: themeEngine.editorFonts.font,
            width: width,
            inset: textView.textContainerInset,
            lineFragmentPadding: textView.textContainer?.lineFragmentPadding ?? 0,
            maxLines: maxLines
        )
        return CGSize(width: width, height: height)
    }

    internal static func fittedHeight(
        of text: String,
        font: NSFont,
        width: CGFloat,
        inset: NSSize,
        lineFragmentPadding: CGFloat,
        maxLines: Int
    ) -> CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let container = NSTextContainer(size: NSSize(
            width: max(width - inset.width * 2, 1),
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = lineFragmentPadding
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let textHeight = max(layoutManager.usedRect(for: container).height, lineHeight)
        return min(textHeight, CGFloat(max(maxLines, 1)) * lineHeight) + inset.height * 2
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator

        // Compared with the coordinator's copy, since `textView.font` answers with the first character's font,
        // which is bold when the text starts with a keyword.
        let editorFont = themeEngine.editorFonts.font
        let fontChanged = coordinator.font != editorFont
        let textChanged = textView.string != sql
        if fontChanged {
            coordinator.font = editorFont
            textView.font = editorFont
        }
        if textChanged {
            textView.string = sql
        }
        // A short query would otherwise show the scroll view's own color below its last line.
        if scrollView.backgroundColor !== textView.backgroundColor {
            scrollView.backgroundColor = textView.backgroundColor
        }

        // The style rewrites the text color of every character when the theme changes, so the syntax is applied
        // again on every change, after the style has run.
        let change = themeEngine.change
        guard !sql.isEmpty,
              textChanged || fontChanged || coordinator.highlighting != highlighting || coordinator.change != change
        else { return }
        coordinator.highlighting = highlighting
        coordinator.change = change
        applyHighlighting(to: textView)
    }

    private func applyLineLayout(to scrollView: NSScrollView, textView: NSTextView) {
        guard let container = textView.textContainer else { return }
        switch lineLayout {
        case .unwrapped:
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
        case .wrapped, .fitted:
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            scrollView.hasHorizontalScroller = false
            // A legacy scroller that stays up while the text fits narrows it below the fitted width.
            scrollView.autohidesScrollers = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        fileprivate var font: NSFont?
        fileprivate var highlighting: Highlighting?
        fileprivate var change: ThemeChange?
        private var themeStyle: ThemeTextViewStyle?
        private var themeCancellable: AnyCancellable?

        fileprivate func attach(to scrollView: NSScrollView, textView: NSTextView) {
            themeStyle = ThemeTextViewStyle(textView: textView, natives: ThemeTextViewStyle.Natives(of: textView))
            scrollView.backgroundColor = textView.backgroundColor
            // An Accent, Highlight or contrast change rewrites none of the colors the text view holds.
            themeCancellable = AppEvents.shared.themeChanged
                .receive(on: RunLoop.main)
                .sink { [weak scrollView] _ in
                    scrollView?.needsDisplay = true
                    scrollView?.documentView?.needsDisplay = true
                }
        }
    }

    // MARK: - Syntax Highlighting

    private var language: CodeLanguage {
        switch highlighting {
        case .json:
            return .json
        case .engine:
            return PluginManager.shared.editorLanguage(for: databaseType).treeSitterLanguage
        }
    }

    private func applyHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage, textStorage.length > 0 else { return }

        let theme = themeEngine.makeEditorTheme()
        let font = themeEngine.editorFonts.font
        let captures = CodeBlockHighlighter.captures(in: textStorage.string, language: language)

        textStorage.beginEditing()
        textStorage.addAttributes(
            [.font: font, .foregroundColor: theme.text.color],
            range: NSRange(location: 0, length: textStorage.length)
        )
        for capture in captures {
            textStorage.addAttributes(
                [
                    .font: theme.fontFor(for: capture.capture, from: font),
                    .foregroundColor: theme.colorFor(capture.capture),
                ],
                range: capture.range
            )
        }
        textStorage.endEditing()
    }
}

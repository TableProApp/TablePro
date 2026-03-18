//
//  SourceEditorConfiguration+Appearance.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/16/25.
//

import AppKit

extension SourceEditorConfiguration {
    /// Configure the appearance of the editor. Font, theme, line height, etc.
    public struct Appearance: Equatable {
        /// The theme for syntax highlighting.
        public var theme: EditorTheme

        /// Determines whether the editor uses the theme's background color, or a transparent background color.
        public var useThemeBackground: Bool = true

        /// The default font.
        public var font: NSFont

        /// The line height multiplier (e.g. `1.2`).
        public var lineHeightMultiple: Double

        /// The amount of space to use between letters, as a percent. Eg: `1.0` = no space, `1.5` = 1/2 a
        /// character's width between characters, etc. Defaults to `1.0`.
        public var letterSpacing: Double = 1.0

        /// Whether lines wrap to the width of the editor.
        public var wrapLines: Bool

        /// If true, uses the system cursor on `>=macOS 14`.
        public var useSystemCursor: Bool = true

        /// The visual tab width in number of spaces.
        public var tabWidth: Int

        /// The type of highlight to use to highlight bracket pairs.
        /// See ``BracketPairEmphasis`` for more information. Defaults to `.flash`.
        public var bracketPairEmphasis: BracketPairEmphasis? = .flash

        /// Create a new appearance configuration object.
        /// - Parameters:
        ///   - theme: The theme for syntax highlighting.
        ///   - useThemeBackground: Determines whether the editor uses the theme's background color, or a transparent
        ///                         background color.
        ///   - font: The default font.
        ///   - lineHeightMultiple: The line height multiplier (e.g. `1.2`).
        ///   - letterSpacing: The amount of space to use between letters, as a percent. Eg: `1.0` = no space, `1.5`
        ///                    = 1/2 of a character's width between characters, etc. Defaults to `1.0`.
        ///   - wrapLines: Whether lines wrap to the width of the editor.
        ///   - useSystemCursor: If true, uses the system cursor on `>=macOS 14`.
        ///   - tabWidth: The visual tab width in number of spaces.
        ///   - bracketPairEmphasis: The type of highlight to use to highlight bracket pairs. See
        ///                          ``BracketPairEmphasis`` for more information. Defaults to `.flash`.
        public init(
            theme: EditorTheme,
            useThemeBackground: Bool = true,
            font: NSFont,
            lineHeightMultiple: Double = 1.2,
            letterSpacing: Double = 1.0,
            wrapLines: Bool,
            useSystemCursor: Bool = true,
            tabWidth: Int = 4,
            bracketPairEmphasis: BracketPairEmphasis? = .flash
        ) {
            self.theme = theme
            self.useThemeBackground = useThemeBackground
            self.font = font
            self.lineHeightMultiple = lineHeightMultiple
            self.letterSpacing = letterSpacing
            self.wrapLines = wrapLines
            if #available(macOS 14, *) {
                self.useSystemCursor = useSystemCursor
            } else {
                self.useSystemCursor = false
            }
            self.tabWidth = tabWidth
            self.bracketPairEmphasis = bracketPairEmphasis
        }

        @MainActor
        func didSetOnController(controller: TextViewController, oldConfig: Appearance?) {
            var needsHighlighterInvalidation = false

            if oldConfig?.font != font {
                controller.textView.font = font
                controller.textView.typingAttributes = controller.attributesFor(nil)
                controller.gutterView.font = font.rulerFont
                needsHighlighterInvalidation = true
            }

            if oldConfig?.theme != theme || oldConfig?.useThemeBackground != useThemeBackground {
                updateControllerNewTheme(controller: controller)
                needsHighlighterInvalidation = true
            }

            if oldConfig?.tabWidth != tabWidth {
                controller.paragraphStyle = controller.generateParagraphStyle()
                controller.textView.layoutManager.setNeedsLayout()
                needsHighlighterInvalidation = true
            }

            if oldConfig?.lineHeightMultiple != lineHeightMultiple {
                controller.textView.layoutManager.lineHeightMultiplier = lineHeightMultiple
            }

            if oldConfig?.wrapLines != wrapLines {
                controller.textView.layoutManager.wrapLines = wrapLines
                controller.minimapView.layoutManager?.wrapLines = wrapLines
                controller.scrollView.hasHorizontalScroller = !wrapLines
                controller.updateTextInsets()
            }

            // useThemeBackground isn't needed

            if oldConfig?.letterSpacing != letterSpacing {
                controller.textView.letterSpacing = letterSpacing
                needsHighlighterInvalidation = true
            }

            if oldConfig?.bracketPairEmphasis != bracketPairEmphasis {
                controller.emphasizeSelectionPairs()
            }

            // Cant put these in one if sadly
            if #available(macOS 14, *) {
                if oldConfig?.useSystemCursor != useSystemCursor {
                    controller.textView.useSystemCursor = useSystemCursor
                }
            }

            if needsHighlighterInvalidation {
                controller.highlighter?.invalidate()
            }
        }

        private func updateControllerNewTheme(controller: TextViewController) {
            controller.textView.layoutManager.setNeedsLayout()
            controller.textView.textStorage.setAttributes(
                controller.attributesFor(nil),
                range: NSRange(location: 0, length: controller.textView.textStorage.length)
            )
            controller.textView.selectionManager.selectionBackgroundColor = theme.selection
            controller.textView.selectionManager.selectedLineBackgroundColor = getThemeBackground(
                systemAppearance: controller.systemAppearance
            )
            controller.textView.selectionManager.insertionPointColor = theme.insertionPoint
            controller.textView.enclosingScrollView?.backgroundColor = if useThemeBackground {
                theme.background
            } else {
                .clear
            }

            controller.gutterView.textColor = theme.text.color.withAlphaComponent(0.35)
            controller.gutterView.selectedLineTextColor = theme.text.color
            controller.gutterView.selectedLineColor = if useThemeBackground {
                theme.lineHighlight
            } else if controller.systemAppearance == .darkAqua {
                NSColor.quaternaryLabelColor
            } else {
                NSColor.selectedTextBackgroundColor.withSystemEffect(.disabled)
            }
            controller.gutterView.backgroundColor = if useThemeBackground {
                theme.background
            } else {
                .windowBackgroundColor
            }

            controller.minimapView.setTheme(theme)
            controller.reformattingGuideView?.theme = theme
            controller.textView.typingAttributes = controller.attributesFor(nil)
        }

        /// Finds the preferred use theme background.
        /// - Returns: The background color to use.
        private func getThemeBackground(systemAppearance: NSAppearance.Name?) -> NSColor {
            if useThemeBackground {
                return theme.lineHighlight
            }

            if systemAppearance == .darkAqua {
                return NSColor.quaternaryLabelColor
            }

            return NSColor.selectedTextBackgroundColor.withSystemEffect(.disabled)
        }
    }
}

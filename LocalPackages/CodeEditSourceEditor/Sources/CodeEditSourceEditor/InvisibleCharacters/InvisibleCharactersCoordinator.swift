//
//  InvisibleCharactersCoordinator.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/9/25.
//

import AppKit
import CodeEditTextView

/// Object that tells the text view how to draw invisible characters.
///
/// Takes a few parameters for contextual drawing such as the current editor theme, font, and indent option.
///
/// To keep lookups fast, does not use a computed property for ``InvisibleCharactersConfiguration/triggerCharacters``.
/// Instead, this type keeps that internal property up-to-date whenever config is updated.
///
/// Another performance optimization is a cache mechanism in CodeEditTextView. Whenever the config, indent option,
/// theme, or font are updated, this object will tell the text view to clear it's cache. Keep updates to a minimum to
/// retain as much cached data as possible.
final class InvisibleCharactersCoordinator: InvisibleCharactersDelegate {
    var configuration: InvisibleCharactersConfiguration {
        didSet {
            updateTriggerCharacters()
        }
    }
    /// A set of characters the editor should draw with a small red border.
    ///
    /// Indicates characters that the user may not have meant to insert, such as a zero-width space: `(0x200D)` or a
    /// non-standard quote character: `“ (0x201C)`.
    public var warningCharacters: Set<UInt16> {
        didSet {
            updateTriggerCharacters()
        }
    }

    var indentOption: IndentOption
    var theme: EditorTheme {
        didSet {
            invisibleColor = theme.invisibles.color
            needsCacheClear = true
        }
    }
    var font: NSFont {
        didSet {
            emphasizedFont = NSFontManager.shared.font(
                withFamily: font.familyName ?? "",
                traits: .unboldFontMask,
                weight: 15, // Condensed
                size: font.pointSize
            ) ?? font
            needsCacheClear = true
        }
    }

    var needsCacheClear = false
    var invisibleColor: NSColor
    var emphasizedFont: NSFont

    /// The set of characters the text view should trigger a call to ``invisibleStyle`` for.
    var triggerCharacters: Set<UInt16> = []

    convenience init(configuration: SourceEditorConfiguration) {
        self.init(
            configuration: configuration.peripherals.invisibleCharactersConfiguration,
            warningCharacters: configuration.peripherals.warningCharacters,
            indentOption: configuration.behavior.indentOption,
            theme: configuration.appearance.theme,
            font: configuration.appearance.font
        )
    }

    init(
        configuration: InvisibleCharactersConfiguration,
        warningCharacters: Set<UInt16>,
        indentOption: IndentOption,
        theme: EditorTheme,
        font: NSFont
    ) {
        self.configuration = configuration
        self.warningCharacters = warningCharacters
        self.indentOption = indentOption
        self.theme = theme
        self.font = font
        invisibleColor = theme.invisibles.color
        emphasizedFont = NSFontManager.shared.font(
            withFamily: font.familyName ?? "",
            traits: .unboldFontMask,
            weight: 15, // Condensed
            size: font.pointSize
        ) ?? font
        updateTriggerCharacters()
    }

    private func updateTriggerCharacters() {
        triggerCharacters = configuration.triggerCharacters().union(warningCharacters)
    }

    /// Determines if the textview should clear cached styles.
    func invisibleStyleShouldClearCache() -> Bool {
        if needsCacheClear {
            needsCacheClear = false
            return true
        }
        return false
    }

    /// Determines the replacement style for a character found in a line fragment. Returns the style the text view
    /// should use to emphasize or replace the character.
    ///
    /// Input is a unichar character (UInt16), and is compared to known characters. This method also emphasizes spaces
    /// that appear on the same column user's selected indent width. The required font is expensive to compute
    /// often and is cached in ``emphasizedFont``.
    func invisibleStyle(for character: UInt16, at range: NSRange, lineRange: NSRange) -> InvisibleCharacterStyle? {
        switch character {
        case InvisibleCharactersConfiguration.Symbols.space:
            return spacesStyle(range: range, lineRange: lineRange)
        case InvisibleCharactersConfiguration.Symbols.tab:
            return tabStyle()
        case InvisibleCharactersConfiguration.Symbols.carriageReturn:
            return carriageReturnStyle()
        case InvisibleCharactersConfiguration.Symbols.lineFeed:
            return lineFeedStyle()
        case InvisibleCharactersConfiguration.Symbols.paragraphSeparator:
            return paragraphSeparatorStyle()
        case InvisibleCharactersConfiguration.Symbols.lineSeparator:
            return lineSeparatorStyle()
        default:
            return warningCharacterStyle(for: character)
        }
    }

    private func spacesStyle(range: NSRange, lineRange: NSRange) -> InvisibleCharacterStyle? {
        guard configuration.showSpaces else { return nil }
        let locationInLine = range.location - lineRange.location
        let shouldBold = locationInLine % indentOption.charCount == indentOption.charCount - 1
        return .replace(
            replacementCharacter: configuration.spaceReplacement,
            color: invisibleColor,
            font: shouldBold ? emphasizedFont : font
        )
    }

    private func tabStyle() -> InvisibleCharacterStyle? {
        guard configuration.showTabs else { return nil }
        return .replace(replacementCharacter: configuration.tabReplacement, color: invisibleColor, font: font)
    }

    private func carriageReturnStyle() -> InvisibleCharacterStyle? {
        guard configuration.showLineEndings else { return nil }
        return .replace(
            replacementCharacter: configuration.carriageReturnReplacement,
            color: invisibleColor,
            font: font
        )
    }

    private func lineFeedStyle() -> InvisibleCharacterStyle? {
        guard configuration.showLineEndings else { return nil }
        return .replace(replacementCharacter: configuration.lineFeedReplacement, color: invisibleColor, font: font)
    }

    private func paragraphSeparatorStyle() -> InvisibleCharacterStyle? {
        guard configuration.showLineEndings else { return nil }
        return .replace(
            replacementCharacter: configuration.paragraphSeparatorReplacement,
            color: invisibleColor,
            font: font
        )
    }

    private func lineSeparatorStyle() -> InvisibleCharacterStyle? {
        guard configuration.showLineEndings else { return nil }
        return .replace(
            replacementCharacter: configuration.lineSeparatorReplacement,
            color: invisibleColor,
            font: font
        )
    }

    private func warningCharacterStyle(for character: UInt16) -> InvisibleCharacterStyle? {
        guard warningCharacters.contains(character) else { return nil }
        return .emphasize(color: .systemRed.withAlphaComponent(0.3))
    }
}

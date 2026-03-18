//
//  InvisibleCharactersConfiguration.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/11/25.
//

/// Configuration for how the editor draws invisible characters.
///
/// Enable specific categories using the ``showSpaces``, ``showTabs``, and ``showLineEndings`` toggles. Customize
/// drawing further with the ``spaceReplacement`` and family variables.
public struct InvisibleCharactersConfiguration: Equatable, Hashable, Sendable, Codable {
    /// An empty configuration.
    public static var empty: InvisibleCharactersConfiguration {
        InvisibleCharactersConfiguration(showSpaces: false, showTabs: false, showLineEndings: false)
    }

    /// Set to true to draw spaces with a dot.
    public var showSpaces: Bool

    /// Set to true to draw tabs with a small arrow.
    public var showTabs: Bool

    /// Set to true to draw line endings.
    public var showLineEndings: Bool

    /// Replacement when drawing the space character, enabled by ``showSpaces``.
    public var spaceReplacement: String = "·"
    /// Replacement when drawing the tab character, enabled by ``showTabs``.
    public var tabReplacement: String = "→"
    /// Replacement when drawing the carriage return character, enabled by ``showLineEndings``.
    public var carriageReturnReplacement: String = "↵"
    /// Replacement when drawing the line feed character, enabled by ``showLineEndings``.
    public var lineFeedReplacement: String = "¬"
    /// Replacement when drawing the paragraph separator character, enabled by ``showLineEndings``.
    public var paragraphSeparatorReplacement: String = "¶"
    /// Replacement when drawing the line separator character, enabled by ``showLineEndings``.
    public var lineSeparatorReplacement: String = "⏎"

    public init(showSpaces: Bool, showTabs: Bool, showLineEndings: Bool) {
        self.showSpaces = showSpaces
        self.showTabs = showTabs
        self.showLineEndings = showLineEndings
    }

    /// Determines what characters should trigger a custom drawing action.
    func triggerCharacters() -> Set<UInt16> {
        var set = Set<UInt16>()

        if showSpaces {
            set.insert(Symbols.space)
        }

        if showTabs {
            set.insert(Symbols.tab)
        }

        if showLineEndings {
            set.insert(Symbols.lineFeed)
            set.insert(Symbols.carriageReturn)
            set.insert(Symbols.paragraphSeparator)
            set.insert(Symbols.lineSeparator)
        }

        return set
    }

    /// Some commonly used whitespace symbols in their unichar representation.
    public enum Symbols {
        public static let space: UInt16 = 0x20
        public static let tab: UInt16 = 0x9
        public static let lineFeed: UInt16 = 0xA // \n
        public static let carriageReturn: UInt16 = 0xD // \r
        public static let paragraphSeparator: UInt16 = 0x2029 // ¶
        public static let lineSeparator: UInt16 = 0x2028 // line separator
    }
}

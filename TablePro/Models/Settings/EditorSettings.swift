//
//  EditorSettings.swift
//  TablePro
//

import AppKit
import Foundation

internal struct FontFamilyOption: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

internal enum EditorFontResolver {
    static let systemMonoId = "System Mono"

    static let availableMonospacedFamilies: [FontFamilyOption] = {
        var options: [FontFamilyOption] = [
            FontFamilyOption(id: systemMonoId, displayName: systemMonoId)
        ]

        let familyNames = NSFontManager.shared.availableFontFamilies
            .filter { $0 != systemMonoId }
            .filter(isMonospacedFamily)
            .sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }

        var seen: Set<String> = [systemMonoId]
        for family in familyNames where !seen.contains(family) {
            seen.insert(family)
            options.append(FontFamilyOption(id: family, displayName: family))
        }

        return options
    }()

    static func resolve(familyId: String, size: CGFloat) -> NSFont {
        guard familyId != systemMonoId else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }

        let descriptor = NSFontDescriptor(fontAttributes: [.family: familyId])
        if let font = NSFont(descriptor: descriptor, size: size),
           font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
            return font
        }

        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func isAvailable(familyId: String) -> Bool {
        guard familyId != systemMonoId else { return true }
        return isMonospacedFamily(familyId)
    }

    private static func isMonospacedFamily(_ familyId: String) -> Bool {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: familyId])
        guard let font = NSFont(descriptor: descriptor, size: 12) else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }
}

internal enum JSONViewMode: String, Codable, CaseIterable {
    case text
    case tree
}

/// Editor settings
struct EditorSettings: Codable, Equatable {
    var showLineNumbers: Bool
    var highlightCurrentLine: Bool
    var tabWidth: Int // 2, 4, or 8 spaces
    var wordWrap: Bool
    var vimModeEnabled: Bool
    var keywordCase: SQLKeywordCase
    var queryParametersEnabled: Bool
    var codeFoldingEnabled: Bool
    var highlightCurrentStatement: Bool
    var showStatementRunControls: Bool
    var showInvisibleCharacters: Bool
    var jsonViewerPreferredMode: JSONViewMode

    static let `default` = EditorSettings(
        showLineNumbers: true,
        highlightCurrentLine: true,
        tabWidth: 4,
        wordWrap: false,
        vimModeEnabled: false,
        keywordCase: .default,
        queryParametersEnabled: true,
        codeFoldingEnabled: true,
        highlightCurrentStatement: true,
        showStatementRunControls: true,
        showInvisibleCharacters: true,
        jsonViewerPreferredMode: .text
    )

    init(
        showLineNumbers: Bool = true,
        highlightCurrentLine: Bool = true,
        tabWidth: Int = 4,
        wordWrap: Bool = false,
        vimModeEnabled: Bool = false,
        keywordCase: SQLKeywordCase = .default,
        queryParametersEnabled: Bool = true,
        codeFoldingEnabled: Bool = true,
        highlightCurrentStatement: Bool = true,
        showStatementRunControls: Bool = true,
        showInvisibleCharacters: Bool = true,
        jsonViewerPreferredMode: JSONViewMode = .text
    ) {
        self.showLineNumbers = showLineNumbers
        self.highlightCurrentLine = highlightCurrentLine
        self.tabWidth = tabWidth
        self.wordWrap = wordWrap
        self.vimModeEnabled = vimModeEnabled
        self.keywordCase = keywordCase
        self.queryParametersEnabled = queryParametersEnabled
        self.codeFoldingEnabled = codeFoldingEnabled
        self.highlightCurrentStatement = highlightCurrentStatement
        self.showStatementRunControls = showStatementRunControls
        self.showInvisibleCharacters = showInvisibleCharacters
        self.jsonViewerPreferredMode = jsonViewerPreferredMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showLineNumbers = try container.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? true
        highlightCurrentLine = try container.decodeIfPresent(Bool.self, forKey: .highlightCurrentLine) ?? true
        tabWidth = try container.decodeIfPresent(Int.self, forKey: .tabWidth) ?? 4
        wordWrap = try container.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? false
        vimModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .vimModeEnabled) ?? false
        keywordCase = try Self.decodeKeywordCase(from: container)
        queryParametersEnabled = try container.decodeIfPresent(Bool.self, forKey: .queryParametersEnabled) ?? true
        codeFoldingEnabled = try container.decodeIfPresent(Bool.self, forKey: .codeFoldingEnabled) ?? true
        highlightCurrentStatement = try container.decodeIfPresent(Bool.self, forKey: .highlightCurrentStatement) ?? true
        showStatementRunControls = try container.decodeIfPresent(Bool.self, forKey: .showStatementRunControls) ?? true
        showInvisibleCharacters = try container.decodeIfPresent(Bool.self, forKey: .showInvisibleCharacters) ?? true
        jsonViewerPreferredMode = try container.decodeIfPresent(JSONViewMode.self, forKey: .jsonViewerPreferredMode) ?? .text
    }

    /// Spelled out rather than synthesized so `uppercaseKeywords` survives as a wire key after the
    /// property it named became `keywordCase`. Editor settings sync as one JSON blob, so both the
    /// key an older build reads and the key this one writes have to be in it.
    private enum CodingKeys: String, CodingKey {
        case showLineNumbers
        case highlightCurrentLine
        case tabWidth
        case wordWrap
        case vimModeEnabled
        case keywordCase
        case uppercaseKeywords
        case queryParametersEnabled
        case codeFoldingEnabled
        case highlightCurrentStatement
        case showStatementRunControls
        case showInvisibleCharacters
        case jsonViewerPreferredMode
    }

    private static func decodeKeywordCase(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> SQLKeywordCase {
        /// A raw value this build does not know falls back rather than throwing. Editor settings
        /// decode as one blob, so a value written by a newer build would otherwise take every
        /// other editor setting down with it.
        if let stored = try? container.decodeIfPresent(SQLKeywordCase.self, forKey: .keywordCase) {
            return stored
        }
        guard let legacy = try container.decodeIfPresent(Bool.self, forKey: .uppercaseKeywords) else {
            return .default
        }
        return legacy ? .upper : .matchTypedElseUpper
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showLineNumbers, forKey: .showLineNumbers)
        try container.encode(highlightCurrentLine, forKey: .highlightCurrentLine)
        try container.encode(tabWidth, forKey: .tabWidth)
        try container.encode(wordWrap, forKey: .wordWrap)
        try container.encode(vimModeEnabled, forKey: .vimModeEnabled)
        try container.encode(keywordCase, forKey: .keywordCase)
        try container.encode(keywordCase == .upper, forKey: .uppercaseKeywords)
        try container.encode(queryParametersEnabled, forKey: .queryParametersEnabled)
        try container.encode(codeFoldingEnabled, forKey: .codeFoldingEnabled)
        try container.encode(highlightCurrentStatement, forKey: .highlightCurrentStatement)
        try container.encode(showStatementRunControls, forKey: .showStatementRunControls)
        try container.encode(showInvisibleCharacters, forKey: .showInvisibleCharacters)
        try container.encode(jsonViewerPreferredMode, forKey: .jsonViewerPreferredMode)
    }

    /// Clamped tab width (1-16)
    var clampedTabWidth: Int {
        min(max(tabWidth, 1), 16)
    }
}

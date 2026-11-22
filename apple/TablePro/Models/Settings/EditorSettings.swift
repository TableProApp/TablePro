import AppKit
import Combine
import CoreText
import Foundation
import TableProAutocomplete

internal struct FontFamilyOption: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

internal enum EditorFontResolver {
    static let systemMonoId = "System Mono"

    // One CoreText query for monospaced faces; asking NSFontManager family by family took 83 to 863 ms.
    static func availableMonospacedFamilies() -> [FontFamilyOption] {
        familyOptions(from: monospacedFamilyNames())
    }

    static func familyOptions(from familyNames: [String]) -> [FontFamilyOption] {
        let names = Set(familyNames)
            .filter { !$0.hasPrefix(".") && $0 != systemMonoId }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [FontFamilyOption(id: systemMonoId, displayName: systemMonoId)]
            + names.map { FontFamilyOption(id: $0, displayName: $0) }
    }

    private static func monospacedFamilyNames() -> [String] {
        let traits = [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitMonoSpace.rawValue] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        guard let matches = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] else {
            return []
        }
        return matches.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
    }

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
}

// The font pickers' list, rebuilt when a font is installed or removed while the app runs.
@MainActor
internal final class MonospacedFontFamilies: ObservableObject {
    internal static let shared = MonospacedFontFamilies()

    @Published internal private(set) var families: [FontFamilyOption]
    private let load: () -> [FontFamilyOption]
    private var fontSetChanges: AnyCancellable?

    internal init(
        notificationCenter: NotificationCenter = .default,
        load: @escaping () -> [FontFamilyOption] = { EditorFontResolver.availableMonospacedFamilies() }
    ) {
        self.load = load
        families = load()
        fontSetChanges = notificationCenter.publisher(for: NSFont.fontSetChangedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reload()
            }
    }

    internal func reload() {
        let latest = load()
        guard latest != families else { return }
        families = latest
    }
}

internal enum JSONViewMode: String, Codable, CaseIterable {
    case text
    case tree
}

internal enum EditorKeyBindings: String, Codable, CaseIterable {
    case standard
    case vim
    case emacs
}

struct EditorSettings: Codable, Equatable {
    var showLineNumbers: Bool
    var highlightCurrentLine: Bool
    var tabWidth: Int
    var wordWrap: Bool
    var keyBindings: EditorKeyBindings
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
        keyBindings: .standard,
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
        keyBindings: EditorKeyBindings = .standard,
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
        self.keyBindings = keyBindings
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
        let fallback = Self.default
        showLineNumbers = container.decodeSetting(.showLineNumbers, default: fallback.showLineNumbers)
        highlightCurrentLine = container.decodeSetting(.highlightCurrentLine, default: fallback.highlightCurrentLine)
        tabWidth = container.decodeSetting(.tabWidth, default: fallback.tabWidth)
        wordWrap = container.decodeSetting(.wordWrap, default: fallback.wordWrap)
        keyBindings = Self.decodeKeyBindings(from: container)
        keywordCase = Self.decodeKeywordCase(from: container)
        queryParametersEnabled = container.decodeSetting(.queryParametersEnabled, default: fallback.queryParametersEnabled)
        codeFoldingEnabled = container.decodeSetting(.codeFoldingEnabled, default: fallback.codeFoldingEnabled)
        highlightCurrentStatement = container.decodeSetting(
            .highlightCurrentStatement, default: fallback.highlightCurrentStatement
        )
        showStatementRunControls = container.decodeSetting(
            .showStatementRunControls, default: fallback.showStatementRunControls
        )
        showInvisibleCharacters = container.decodeSetting(
            .showInvisibleCharacters, default: fallback.showInvisibleCharacters
        )
        jsonViewerPreferredMode = container.decodeSetting(
            .jsonViewerPreferredMode, default: fallback.jsonViewerPreferredMode
        )
    }

    // Synced as one blob, so the legacy uppercaseKeywords and vimModeEnabled keys stay for older builds.
    private enum CodingKeys: String, CodingKey {
        case showLineNumbers
        case highlightCurrentLine
        case tabWidth
        case wordWrap
        case keyBindings
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

    private static func decodeKeywordCase(from container: KeyedDecodingContainer<CodingKeys>) -> SQLKeywordCase {
        if let stored: SQLKeywordCase = container.decodeSetting(.keywordCase) {
            return stored
        }
        guard let legacy: Bool = container.decodeSetting(.uppercaseKeywords) else {
            return .default
        }
        return legacy ? .upper : .matchTypedElseUpper
    }

    private static func decodeKeyBindings(from container: KeyedDecodingContainer<CodingKeys>) -> EditorKeyBindings {
        if let stored: EditorKeyBindings = container.decodeSetting(.keyBindings) {
            return stored
        }
        let legacyVim: Bool = container.decodeSetting(.vimModeEnabled) ?? false
        return legacyVim ? .vim : .standard
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showLineNumbers, forKey: .showLineNumbers)
        try container.encode(highlightCurrentLine, forKey: .highlightCurrentLine)
        try container.encode(tabWidth, forKey: .tabWidth)
        try container.encode(wordWrap, forKey: .wordWrap)
        try container.encode(keyBindings, forKey: .keyBindings)
        try container.encode(keyBindings == .vim, forKey: .vimModeEnabled)
        try container.encode(keywordCase, forKey: .keywordCase)
        try container.encode(keywordCase == .upper, forKey: .uppercaseKeywords)
        try container.encode(queryParametersEnabled, forKey: .queryParametersEnabled)
        try container.encode(codeFoldingEnabled, forKey: .codeFoldingEnabled)
        try container.encode(highlightCurrentStatement, forKey: .highlightCurrentStatement)
        try container.encode(showStatementRunControls, forKey: .showStatementRunControls)
        try container.encode(showInvisibleCharacters, forKey: .showInvisibleCharacters)
        try container.encode(jsonViewerPreferredMode, forKey: .jsonViewerPreferredMode)
    }

    var clampedTabWidth: Int {
        min(max(tabWidth, 1), 16)
    }
}

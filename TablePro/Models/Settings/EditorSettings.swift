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
    var uppercaseKeywords: Bool
    var jsonViewerPreferredMode: JSONViewMode

    static let `default` = EditorSettings(
        showLineNumbers: true,
        highlightCurrentLine: true,
        tabWidth: 4,
        wordWrap: false,
        vimModeEnabled: false,
        uppercaseKeywords: false,
        jsonViewerPreferredMode: .text
    )

    init(
        showLineNumbers: Bool = true,
        highlightCurrentLine: Bool = true,
        tabWidth: Int = 4,
        wordWrap: Bool = false,
        vimModeEnabled: Bool = false,
        uppercaseKeywords: Bool = false,
        jsonViewerPreferredMode: JSONViewMode = .text
    ) {
        self.showLineNumbers = showLineNumbers
        self.highlightCurrentLine = highlightCurrentLine
        self.tabWidth = tabWidth
        self.wordWrap = wordWrap
        self.vimModeEnabled = vimModeEnabled
        self.uppercaseKeywords = uppercaseKeywords
        self.jsonViewerPreferredMode = jsonViewerPreferredMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showLineNumbers = try container.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? true
        highlightCurrentLine = try container.decodeIfPresent(Bool.self, forKey: .highlightCurrentLine) ?? true
        tabWidth = try container.decodeIfPresent(Int.self, forKey: .tabWidth) ?? 4
        wordWrap = try container.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? false
        vimModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .vimModeEnabled) ?? false
        uppercaseKeywords = try container.decodeIfPresent(Bool.self, forKey: .uppercaseKeywords) ?? false
        jsonViewerPreferredMode = try container.decodeIfPresent(JSONViewMode.self, forKey: .jsonViewerPreferredMode) ?? .text
    }

    /// Clamped tab width (1-16)
    var clampedTabWidth: Int {
        min(max(tabWidth, 1), 16)
    }
}

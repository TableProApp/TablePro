import Foundation

/// Default Light and Default Dark set no color at all: every slot draws its fallback, so a copy of
/// one keeps following Increase Contrast. They are values, not files, because every other theme
/// falls back to them and they cannot themselves fail to load.
public extension ThemeDefinition {
    static let defaultLight = ThemeDefinition(
        id: "tablepro.default-light",
        name: String(localized: "Default Light"),
        author: "TablePro",
        appearance: .light,
        overrides: [:]
    )

    static let defaultDark = ThemeDefinition(
        id: "tablepro.default-dark",
        name: String(localized: "Default Dark"),
        author: "TablePro",
        appearance: .dark,
        overrides: [:]
    )

    static func `default`(for appearance: ThemeAppearance) -> ThemeDefinition {
        switch appearance {
        case .light: return defaultLight
        case .dark: return defaultDark
        }
    }

    static func defaultId(for appearance: ThemeAppearance) -> String {
        self.default(for: appearance).id
    }

    static func isDefault(_ id: String) -> Bool {
        id == defaultLight.id || id == defaultDark.id
    }
}

/// Xcode's Default and High Contrast syntax colors, for the syntax slots a theme leaves out. SQL
/// `NULL` takes the keyword color the way Swift's `nil` does; built-in functions and types take
/// Xcode's colors for system-provided ones. Operator has no entry: it follows the editor text.
public enum DefaultSyntaxPalette {
    public static func colors(for appearance: ThemeAppearance, highContrast: Bool) -> [ThemeSlot: ThemeColor] {
        switch (appearance, highContrast) {
        case (.light, false): return standardLight
        case (.light, true): return highContrastLight
        case (.dark, false): return standardDark
        case (.dark, true): return highContrastDark
        }
    }

    public static func color(for slot: ThemeSlot, appearance: ThemeAppearance, highContrast: Bool) -> ThemeColor? {
        colors(for: appearance, highContrast: highContrast)[slot]
    }

    private static let standardLight = syntax(
        keyword: 0x9B2393, string: 0xC41A16, number: 0x1C00CF, comment: 0x5D6C79, function: 0x6C36A9, type: 0x3900A0
    )

    private static let highContrastLight = syntax(
        keyword: 0x88007E, string: 0x9B0509, number: 0x1C02CF, comment: 0x1A5301, function: 0x5C2699, type: 0x330090
    )

    private static let standardDark = syntax(
        keyword: 0xFC5FA3, string: 0xFC6A5D, number: 0xD0BF69, comment: 0x6C7986, function: 0xA167E6, type: 0xD0A8FF
    )

    private static let highContrastDark = syntax(
        keyword: 0xFC6BAA, string: 0xFC7467, number: 0xD0BC56, comment: 0x7CB554, function: 0xC08AFF, type: 0xDEC1FF
    )

    private static func syntax(
        keyword: UInt32,
        string: UInt32,
        number: UInt32,
        comment: UInt32,
        function: UInt32,
        type: UInt32
    ) -> [ThemeSlot: ThemeColor] {
        [
            .syntaxKeyword: rgb(keyword),
            .syntaxNull: rgb(keyword),
            .syntaxString: rgb(string),
            .syntaxNumber: rgb(number),
            .syntaxComment: rgb(comment),
            .syntaxFunction: rgb(function),
            .syntaxType: rgb(type),
        ]
    }

    private static func rgb(_ value: UInt32) -> ThemeColor {
        ThemeColor(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }
}

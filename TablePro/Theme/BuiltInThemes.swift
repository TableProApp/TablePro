import AppKit

/// Default Light and Default Dark override nothing but syntax, so every other slot draws in the
/// system color. The syntax values are Xcode's Default (Light) and Default (Dark): SQL `NULL` takes
/// the keyword color the way Swift's `nil` does, and built-in functions and types take Xcode's
/// colors for system-provided functions and types. They are Swift, not files, because every other
/// theme falls back to them and they cannot themselves fail to load.
internal enum BuiltInThemes {
    internal static let defaultLightId = "tablepro.default-light"
    internal static let defaultDarkId = "tablepro.default-dark"

    internal static let light = ThemeDefinition(
        id: defaultLightId,
        name: String(localized: "Default Light"),
        author: "TablePro",
        appearance: .light,
        overrides: syntax(
            keyword: "#9B2393",
            string: "#C41A16",
            number: "#1C00CF",
            comment: "#5D6C79",
            function: "#6C36A9",
            type: "#3900A0"
        )
    )

    internal static let dark = ThemeDefinition(
        id: defaultDarkId,
        name: String(localized: "Default Dark"),
        author: "TablePro",
        appearance: .dark,
        overrides: syntax(
            keyword: "#FC5FA3",
            string: "#FC6A5D",
            number: "#D0BF69",
            comment: "#6C7986",
            function: "#A167E6",
            type: "#D0A8FF"
        )
    )

    internal static let all: [ThemeDefinition] = [light, dark]

    internal static func isDefault(_ id: String) -> Bool {
        id == defaultLightId || id == defaultDarkId
    }

    /// Xcode's High Contrast (Light) and High Contrast (Dark) syntax values, drawn when the view's
    /// appearance is an increased-contrast one.
    private static let highContrastLight = syntax(
        keyword: "#88007E",
        string: "#9B0509",
        number: "#1C02CF",
        comment: "#1A5301",
        function: "#5C2699",
        type: "#330090"
    )

    private static let highContrastDark = syntax(
        keyword: "#FC6BAA",
        string: "#FC7467",
        number: "#D0BC56",
        comment: "#7CB554",
        function: "#C08AFF",
        type: "#DEC1FF"
    )

    private static let adaptiveLight = adaptive(standard: light.overrides, highContrast: highContrastLight)
    private static let adaptiveDark = adaptive(standard: dark.overrides, highContrast: highContrastDark)

    internal static func adaptiveSyntaxColor(_ slot: ThemeSlot, appearance: ThemeAppearance) -> NSColor? {
        switch appearance {
        case .light: return adaptiveLight[slot]
        case .dark: return adaptiveDark[slot]
        }
    }

    private static func adaptive(
        standard: [ThemeSlot: ThemeColor],
        highContrast: [ThemeSlot: ThemeColor]
    ) -> [ThemeSlot: NSColor] {
        var colors: [ThemeSlot: NSColor] = [:]
        for (slot, color) in standard {
            let contrast = highContrast[slot] ?? color
            colors[slot] = NSColor(name: NSColor.Name("tablepro.syntax.\(slot.rawValue).\(color.hex)")) { appearance in
                appearance.isHighContrast ? contrast.nsColor : color.nsColor
            }
        }
        return colors
    }

    internal static func `default`(for appearance: ThemeAppearance) -> ThemeDefinition {
        switch appearance {
        case .light: return light
        case .dark: return dark
        }
    }

    internal static func defaultId(for appearance: ThemeAppearance) -> String {
        `default`(for: appearance).id
    }

    private static func syntax(
        keyword: String,
        string: String,
        number: String,
        comment: String,
        function: String,
        type: String
    ) -> [ThemeSlot: ThemeColor] {
        let values: [ThemeSlot: String] = [
            .syntaxKeyword: keyword,
            .syntaxNull: keyword,
            .syntaxString: string,
            .syntaxNumber: number,
            .syntaxComment: comment,
            .syntaxFunction: function,
            .syntaxType: type,
        ]
        return values.compactMapValues { try? ThemeColor(validating: $0) }
    }
}

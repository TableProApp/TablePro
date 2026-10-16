import AppKit
import TableProTheme

/// The app's names for the package defaults, and the AppKit side of their syntax palette.
internal enum BuiltInThemes {
    internal static let defaultLightId = ThemeDefinition.defaultId(for: .light)
    internal static let defaultDarkId = ThemeDefinition.defaultId(for: .dark)

    internal static var light: ThemeDefinition { .defaultLight }
    internal static var dark: ThemeDefinition { .defaultDark }
    internal static var all: [ThemeDefinition] { [.defaultLight, .defaultDark] }

    internal static func isDefault(_ id: String) -> Bool {
        ThemeDefinition.isDefault(id)
    }

    internal static func `default`(for appearance: ThemeAppearance) -> ThemeDefinition {
        .default(for: appearance)
    }

    internal static func defaultId(for appearance: ThemeAppearance) -> String {
        ThemeDefinition.defaultId(for: appearance)
    }

    /// Switches to Xcode's high-contrast palette when the drawing view's appearance is an
    /// increased-contrast one.
    internal static func adaptiveSyntaxColor(_ slot: ThemeSlot, appearance: ThemeAppearance) -> NSColor? {
        switch appearance {
        case .light: return adaptiveLight[slot]
        case .dark: return adaptiveDark[slot]
        }
    }

    private static let adaptiveLight = adaptive(.light)
    private static let adaptiveDark = adaptive(.dark)

    private static func adaptive(_ appearance: ThemeAppearance) -> [ThemeSlot: NSColor] {
        let standard = DefaultSyntaxPalette.colors(for: appearance, highContrast: false)
        let highContrast = DefaultSyntaxPalette.colors(for: appearance, highContrast: true)
        var colors: [ThemeSlot: NSColor] = [:]
        for (slot, color) in standard {
            let contrast = (highContrast[slot] ?? color).nsColor
            let regular = color.nsColor
            colors[slot] = NSColor(name: NSColor.Name("tablepro.syntax.\(slot.rawValue).\(color.hex)")) { drawing in
                drawing.isHighContrast ? contrast : regular
            }
        }
        return colors
    }
}

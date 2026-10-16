import AppKit
import TableProTheme

internal extension ThemeDefinition {
    /// The format has no increased-contrast variant, so a slot that yields to Increase Contrast draws
    /// native in an increased-contrast appearance even where the theme sets it.
    func isOverridden(_ slot: ThemeSlot, in appearance: NSAppearance) -> Bool {
        isOverridden(slot, highContrast: appearance.isHighContrast)
    }

    func color(for slot: ThemeSlot, in appearance: NSAppearance) -> NSColor {
        nsColor(of: value(for: slot, highContrast: appearance.isHighContrast))
    }

    /// A slot that falls back to the system hands back the system color object itself, which
    /// resolves at draw time against the drawing view's appearance, accent and contrast.
    func color(for slot: ThemeSlot) -> NSColor {
        nsColor(of: value(for: slot, highContrast: false))
    }

    private func nsColor(of value: ThemeSlotValue) -> NSColor {
        switch value {
        case let .themed(color):
            return color.nsColor
        case let .system(slot):
            return slot.nativeColor
        case let .defaultSyntax(slot):
            return BuiltInThemes.adaptiveSyntaxColor(slot, appearance: appearance) ?? slot.nativeColor
        }
    }
}

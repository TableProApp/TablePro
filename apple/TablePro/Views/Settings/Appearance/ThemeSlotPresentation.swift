import AppKit
import TableProTheme

// Text, not color alone, tells a set slot from one that follows the system.
internal struct ThemeSlotPresentation: Equatable {
    internal let slot: ThemeSlot
    internal let hasExplicitColor: Bool
    internal let displayColor: ThemeColor
    internal let stateLine: String
    internal let resetTitle: String
    internal let resetAccessibilityLabel: String

    internal init(slot: ThemeSlot, theme: ThemeDefinition) {
        self.slot = slot
        hasExplicitColor = theme.hasExplicitColor(slot)
        displayColor = Self.displayColor(for: slot, in: theme)
        stateLine = Self.stateLine(for: slot, in: theme)
        resetTitle = Self.resetTitle(for: slot, in: theme)
        resetAccessibilityLabel = Self.resetsToSystem(slot, in: theme)
            ? String(format: String(localized: "Use System Color for %@"), slot.accessibilityLabel)
            : String(format: String(localized: "Use Default Color for %@"), slot.accessibilityLabel)
    }

    // An unset slot shows the system color in the theme's own appearance, not the editor window's.
    internal static func displayColor(for slot: ThemeSlot, in theme: ThemeDefinition) -> ThemeColor {
        switch theme.value(for: slot) {
        case let .themed(color):
            return color
        case let .defaultSyntax(source):
            return DefaultSyntaxPalette.color(for: source, appearance: theme.appearance, highContrast: false)
                ?? resolved(source.nativeColor, in: theme.appearance)
        case let .system(source):
            return resolved(source.nativeColor, in: theme.appearance)
        }
    }

    internal static func stateLine(for slot: ThemeSlot, in theme: ThemeDefinition) -> String {
        if let explicit = theme.overrides[slot] {
            return explicit.hex
        }
        switch theme.value(for: slot) {
        case .system:
            return String(localized: "System color")
        case .defaultSyntax:
            switch theme.appearance {
            case .light: return String(localized: "Default Light color")
            case .dark: return String(localized: "Default Dark color")
            }
        case .themed:
            guard let source = slot.fallbackSource else { return String(localized: "System color") }
            return String(format: String(localized: "Based on %@"), source.accessibilityLabel)
        }
    }

    internal static func resetTitle(for slot: ThemeSlot, in theme: ThemeDefinition) -> String {
        resetsToSystem(slot, in: theme)
            ? String(localized: "Use System Color")
            : String(localized: "Use Default Color")
    }

    private static func resetsToSystem(_ slot: ThemeSlot, in theme: ThemeDefinition) -> Bool {
        var cleared = theme
        cleared.overrides[slot] = nil
        if case .system = cleared.value(for: slot) {
            return true
        }
        return false
    }

    private static func resolved(_ color: NSColor, in appearance: ThemeAppearance) -> ThemeColor {
        guard let drawing = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) else {
            return ThemeColor(color)
        }
        var result = ThemeColor(color)
        drawing.performAsCurrentDrawingAppearance {
            result = ThemeColor(color.usingColorSpace(.sRGB) ?? color)
        }
        return result
    }
}

internal enum ThemeContrastNote {
    internal static let minimumRatio = 4.5

    // NULL draws a placeholder, not a value. An unset value color is the grid text, which the Data Grid note checks.
    private static func checks(
        for section: ThemeSlotSection,
        in theme: ThemeDefinition
    ) -> (texts: [ThemeSlot], surfaces: [ThemeColor])? {
        switch section {
        case .editor:
            return ([.editorText], [color(.editorBackground, in: theme).opaque])
        case .dataGrid:
            return ([.gridText], [color(.gridBackground, in: theme).opaque])
        case .values:
            let explicit = ThemeSlotSection.values.slots.filter { $0 != .gridNullValue && theme.hasExplicitColor($0) }
            return (explicit, rowSurfaces(in: theme))
        case .window, .syntax, .selection, .changes:
            return nil
        }
    }

    // Alternate rows are on by default, and a modified cell or an inserted row washes either row.
    private static func rowSurfaces(in theme: ThemeDefinition) -> [ThemeColor] {
        let background = color(.gridBackground, in: theme).opaque
        let rows = [background, color(.gridAlternateRow, in: theme).composited(over: background)]
        let washes = [color(.gridModified, in: theme), color(.gridInserted, in: theme)]
        return rows + washes.flatMap { wash in rows.map { wash.composited(over: $0) } }
    }

    internal static func lowest(for section: ThemeSlotSection, in theme: ThemeDefinition) -> (slot: ThemeSlot, ratio: Double)? {
        guard let checks = checks(for: section, in: theme) else { return nil }
        return checks.texts
            .map { slot in
                let text = color(slot, in: theme)
                let ratios = checks.surfaces.map { text.composited(over: $0).contrastRatio(with: $0) }
                return (slot: slot, ratio: ratios.min() ?? .infinity)
            }
            .min { $0.ratio < $1.ratio }
    }

    private static func color(_ slot: ThemeSlot, in theme: ThemeDefinition) -> ThemeColor {
        ThemeSlotPresentation.displayColor(for: slot, in: theme)
    }

    internal static func message(for section: ThemeSlotSection, in theme: ThemeDefinition) -> String? {
        guard let lowest = lowest(for: section, in: theme), lowest.ratio < minimumRatio else { return nil }
        let formatted = lowest.ratio.formatted(.number.precision(.fractionLength(1)))
        switch section {
        case .values:
            return String(
                format: String(localized: "%1$@ contrast is %2$@:1. Aim for at least 4.5:1."),
                lowest.slot.label,
                formatted
            )
        case .window, .editor, .syntax, .dataGrid, .selection, .changes:
            return String(format: String(localized: "Text contrast is %@:1. Aim for at least 4.5:1."), formatted)
        }
    }
}

internal enum ThemeValueColorsNote {
    internal static func message(for section: ThemeSlotSection, colorsValuesByType: Bool) -> String? {
        guard section == .values, !colorsValuesByType else { return nil }
        return String(
            localized: "Except NULL and booleans, these colors show in the grid only while Color values by type is on in Settings > Data."
        )
    }
}

private extension ThemeSlot {
    var fallbackSource: ThemeSlot? {
        switch fallback {
        case .system, .defaultSyntax: return nil
        case let .slot(source): return source
        case let .derived(base, _): return base
        }
    }
}

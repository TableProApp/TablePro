import AppKit
import os
import SwiftUI

internal struct ThemePair: Equatable, Sendable {
    var light: ThemeDefinition
    var dark: ThemeDefinition

    internal subscript(appearance: ThemeAppearance) -> ThemeDefinition {
        switch appearance {
        case .light: return light
        case .dark: return dark
        }
    }

    internal static let builtIn = ThemePair(light: BuiltInThemes.light, dark: BuiltInThemes.dark)
}

/// The live pair every dynamic slot colour reads through. A colour object an AppKit view is
/// already holding therefore answers for the theme in effect now, the way `NSColor.labelColor`
/// does, so marking that view for display is enough. Capturing the pair inside the provider
/// instead would freeze each colour at the revision that built it.
internal final class ThemeSource: Sendable {
    internal static let shared = ThemeSource()

    private let state = OSAllocatedUnfairLock(initialState: ThemePair.builtIn)

    internal var pair: ThemePair {
        state.withLock { $0 }
    }

    internal func update(_ pair: ThemePair) {
        state.withLock { $0 = pair }
    }
}

/// The dynamic tier. One `NSColor(name:dynamicProvider:)` per slot, reading the live pair, so a
/// color an AppKit view already holds answers for the theme in effect and for the appearance the
/// view draws in. A slot the theme leaves out returns the system color itself, which AppKit then
/// resolves for that same appearance, including vibrancy, accent, highlight and contrast.
/// The revision only names the color: SwiftUI caches `Color(nsColor:)` by object identity, so a
/// stable object would never repaint on a theme swap even though the provider answers correctly.
internal struct ThemePalette {
    internal let revision: Int

    private let colors: [ThemeSlot: NSColor]
    private let source: ThemeSource

    internal init(revision: Int, source: ThemeSource = .shared) {
        self.revision = revision
        self.source = source

        var built: [ThemeSlot: NSColor] = [:]
        built.reserveCapacity(ThemeSlot.allCases.count)

        for slot in ThemeSlot.allCases {
            let name = NSColor.Name("tablepro.\(slot.rawValue).\(revision)")
            built[slot] = NSColor(name: name) { appearance in
                source.pair[ThemeAppearance(matching: appearance)].color(for: slot, in: appearance)
            }
        }

        colors = built
    }

    internal subscript(slot: ThemeSlot) -> NSColor {
        colors[slot] ?? slot.nativeColor
    }

    internal func color(_ slot: ThemeSlot) -> Color {
        Color(nsColor: self[slot])
    }

    /// For a surface that has its own system color today: the theme's color in each appearance whose
    /// theme sets the slot, and `native` itself, still dynamic, in the other.
    /// Unnamed, because two dynamic colors with one name compare equal whatever they draw.
    internal func color(_ slot: ThemeSlot, otherwise native: NSColor) -> NSColor {
        let source = source
        return NSColor(name: nil) { appearance in
            let theme = source.pair[ThemeAppearance(matching: appearance)]
            return theme.isOverridden(slot, in: appearance) ? theme.color(for: slot) : native
        }
    }
}

/// The active theme's colors for code that holds on to them: the editor theme, a `CALayer`, the
/// grid's per-cell drawing. A slot the theme overrides is a fixed sRGB color; a slot it leaves out
/// is the system color object itself, never a flattened copy, so text drawn with it still resolves
/// at draw time against the view's real appearance. Turning one into a `CGColor` happens in the
/// drawing view's appearance (`cgColor(_:in:)`), never against a hand-built `NSAppearance(named:)`,
/// which has no vibrancy and no increased-contrast variant.
internal struct ResolvedTheme: Equatable {
    internal let definition: ThemeDefinition

    private let colors: [ThemeSlot: NSColor]

    internal init(definition: ThemeDefinition) {
        self.definition = definition

        var built: [ThemeSlot: NSColor] = [:]
        built.reserveCapacity(ThemeSlot.allCases.count)
        for slot in ThemeSlot.allCases {
            built[slot] = definition.color(for: slot)
        }
        colors = built
    }

    internal static func == (lhs: ResolvedTheme, rhs: ResolvedTheme) -> Bool {
        lhs.definition == rhs.definition
    }

    internal var appearance: ThemeAppearance { definition.appearance }

    internal subscript(slot: ThemeSlot) -> NSColor {
        colors[slot] ?? slot.nativeColor
    }

    internal func isOverridden(_ slot: ThemeSlot) -> Bool {
        definition.isOverridden(slot)
    }

    internal func color(_ slot: ThemeSlot) -> Color {
        Color(nsColor: self[slot])
    }

    /// The override when the active theme sets the slot, else `native` itself.
    internal func color(_ slot: ThemeSlot, otherwise native: NSColor) -> NSColor {
        guard isOverridden(slot) else { return native }
        guard slot.yieldsToIncreasedContrast else { return self[slot] }
        let override = self[slot]
        return NSColor(name: nil) { appearance in
            appearance.isHighContrast ? native : override
        }
    }

    /// A view drawing in the other appearance than the active theme (a preview of the other slot)
    /// takes that slot's theme, the way a `palette` color would.
    internal func cgColor(_ slot: ThemeSlot, in appearance: NSAppearance) -> CGColor {
        let color = ThemeAppearance(matching: appearance) == definition.appearance
            ? self[slot]
            : ThemeSource.shared.pair[ThemeAppearance(matching: appearance)].color(for: slot)
        return Self.cgColor(color, in: appearance)
    }

    internal func cgColor(_ slot: ThemeSlot, otherwise native: NSColor, in appearance: NSAppearance) -> CGColor {
        let theme = ThemeAppearance(matching: appearance) == definition.appearance
            ? definition
            : ThemeSource.shared.pair[ThemeAppearance(matching: appearance)]
        return Self.cgColor(theme.isOverridden(slot, in: appearance) ? theme.color(for: slot) : native, in: appearance)
    }

    private static func cgColor(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        var result: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result ?? color.cgColor
    }
}

internal extension ThemeAppearance {
    init(matching appearance: NSAppearance) {
        self = appearance.isDarkTheme ? .dark : .light
    }
}

/// Sent whenever a color a view may have baked could have changed: a theme or pair change, a
/// light/dark flip, an Accent or Highlight change, or an Increase Contrast toggle. `generation`
/// moves on every send, so two sends are never equal.
internal struct ThemeChange: Equatable, Sendable {
    internal let revision: Int
    internal let appearance: ThemeAppearance
    internal let generation: Int
}

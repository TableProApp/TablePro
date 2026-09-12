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

/// The dynamic tier. One `NSColor(name:dynamicProvider:)` per slot, so a slot resolves against
/// whatever appearance the view is drawing in, including the vibrant appearances inside a sidebar.
/// The revision only names the colour: SwiftUI caches `Color(nsColor:)` by object identity, so a
/// stable object would never repaint on a theme swap even though the provider answers correctly.
internal struct ThemePalette {
    internal let revision: Int

    private let colors: [ThemeSlot: NSColor]

    internal init(revision: Int, source: ThemeSource = .shared) {
        self.revision = revision

        var built: [ThemeSlot: NSColor] = [:]
        built.reserveCapacity(ThemeSlot.allCases.count)

        for slot in ThemeSlot.allCases {
            let name = NSColor.Name("tablepro.\(slot.rawValue).\(revision)")
            built[slot] = NSColor(name: name) { appearance in
                let definition = source.pair[ThemeAppearance(matching: appearance)]
                return definition[keyPath: slot.keyPath].nsColor
            }
        }

        colors = built
    }

    internal subscript(slot: ThemeSlot) -> NSColor {
        colors[slot] ?? .labelColor
    }

    internal func color(_ slot: ThemeSlot) -> Color {
        Color(nsColor: self[slot])
    }
}

/// The static tier. Snapshot consumers (the CodeEdit `EditorTheme`, `CALayer` colours, the data
/// grid's per-cell draw path) resolve once against the appearance the app has actually settled on.
/// They must not resolve a dynamic colour implicitly: outside a draw pass
/// `NSAppearance.currentDrawing()` still reports the old appearance for at least half a second
/// after `NSApp.appearance` changes, and a dynamic `cgColor` costs 254ns against 11ns for a
/// static one, which the grid pays per cell.
internal struct ResolvedTheme: Equatable {
    internal let definition: ThemeDefinition
    internal let appearance: ThemeAppearance

    private let colors: [ThemeSlot: NSColor]

    internal init(definition: ThemeDefinition, appearance: ThemeAppearance) {
        self.definition = definition
        self.appearance = appearance

        let nsAppearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        var built: [ThemeSlot: NSColor] = [:]
        built.reserveCapacity(ThemeSlot.allCases.count)

        let resolve = {
            for slot in ThemeSlot.allCases {
                let value = definition[keyPath: slot.keyPath]
                built[slot] = value.nsColor.usingColorSpace(.sRGB) ?? value.nsColor
            }
        }

        if let nsAppearance {
            nsAppearance.performAsCurrentDrawingAppearance(resolve)
        } else {
            resolve()
        }

        colors = built
    }

    internal subscript(slot: ThemeSlot) -> NSColor {
        colors[slot] ?? .labelColor
    }

    internal func color(_ slot: ThemeSlot) -> Color {
        Color(nsColor: self[slot])
    }

    internal func cgColor(_ slot: ThemeSlot) -> CGColor {
        self[slot].cgColor
    }
}

internal extension ThemeAppearance {
    init(matching appearance: NSAppearance) {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua])
        self = match == .darkAqua ? .dark : .light
    }
}

/// Sent on a theme change and on an effective-appearance change, because the snapshot consumers
/// need both: a forced Light/Dark switch never changes the theme pair, and a theme switch never
/// changes the appearance.
internal struct ThemeChange: Equatable, Sendable {
    internal let revision: Int
    internal let appearance: ThemeAppearance
}

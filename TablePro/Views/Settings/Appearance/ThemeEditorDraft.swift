import AppKit

/// The theme an Edit sheet is changing. Each mutation reports whether it changed anything, so the
/// sheet schedules a save only for a real edit.
internal struct ThemeEditorDraft: Equatable {
    internal var theme: ThemeDefinition

    /// The color a well shows. A slot the theme leaves out shows the system color it draws in,
    /// resolved in the theme's appearance rather than the one Settings is in.
    internal func displayColor(for slot: ThemeSlot) -> NSColor {
        let color = theme.color(for: slot)
        guard !theme.isOverridden(slot),
              let appearance = NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)
        else { return color }

        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    /// A well can echo the color it was handed. Taking that echo as an edit would freeze a system
    /// color into the file as a fixed value, so a value equal to what the well shows is ignored.
    @discardableResult
    internal mutating func setColor(_ color: ThemeColor, for slot: ThemeSlot) -> Bool {
        if let existing = theme.overrides[slot] {
            guard existing != color else { return false }
        } else {
            guard ThemeColor(displayColor(for: slot)) != color else { return false }
        }
        theme.overrides[slot] = color
        return true
    }

    @discardableResult
    internal mutating func reset(_ slot: ThemeSlot) -> Bool {
        theme.overrides.removeValue(forKey: slot) != nil
    }

    @discardableResult
    internal mutating func rename(to name: String) -> Bool {
        guard name != theme.name else { return false }
        theme.name = name
        return true
    }
}

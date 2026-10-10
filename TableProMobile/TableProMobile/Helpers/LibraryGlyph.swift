import TableProConnectionLibrary
import TableProModels
import UIKit

/// The shape a connection or a group draws. A custom icon replaces the shape only: every surface
/// keeps its own tint rule, so the engine colour and the connection's identity colour stay apart.
nonisolated enum LibraryGlyph {
    static let defaultGroupSymbol = "folder"

    /// The user's icon when this device can draw it. A record synced from a newer release can name a
    /// symbol this iOS does not have, and that draws the default rather than an empty tile.
    static func customSymbol(_ iconName: String?) -> String? {
        guard let name = LibrarySymbolCatalog.normalizedName(iconName), UIImage(systemName: name) != nil else {
            return nil
        }
        return name
    }

    /// Groups draw the filled variant, as the folder always has. Some symbols gained a fill only in a
    /// later release (`globe.fill` is iOS 26), so the outline stands in when the fill is missing.
    static func groupSymbol(_ iconName: String?) -> String {
        filledVariant(of: customSymbol(iconName) ?? defaultGroupSymbol)
    }

    static func filledVariant(of name: String) -> String {
        let filled = name + ".fill"
        return UIImage(systemName: filled) == nil ? name : filled
    }

    static func connectionGlyph(type: DatabaseType, iconName: String?) -> ConnectionGlyph {
        guard let symbol = customSymbol(iconName) else { return engineGlyph(for: type) }
        return ConnectionGlyph(source: .symbol, name: symbol)
    }

    /// Engines ship either a brand asset or an SF Symbol name, and an engine added on the Mac can
    /// name an asset this app does not bundle.
    static func engineGlyph(for type: DatabaseType) -> ConnectionGlyph {
        let name = type.iconName
        guard name.hasSuffix("-icon") else { return ConnectionGlyph(source: .symbol, name: name) }
        guard UIImage(named: name) != nil else { return .fallback }
        return ConnectionGlyph(source: .asset, name: name)
    }

    static func title(for iconName: String?) -> String {
        guard let symbol = customSymbol(iconName) else { return String(localized: "Default") }
        return LibrarySymbolCatalog.symbol(named: symbol)?.title ?? symbol
    }
}

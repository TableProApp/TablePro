//
//  LibraryGlyph.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProConnectionLibrary

/// The shape a connection or a group draws. A custom icon replaces the shape only: every surface
/// keeps its own tint rule, so the engine's brand colour and the connection's identity colour stay
/// the two separate channels they are (#2398).
@MainActor
internal enum LibraryGlyph {
    static let defaultGroupSymbol = "folder"

    /// The user's icon when this Mac can draw it. A record synced from a newer release can name a
    /// symbol this macOS does not have, and that draws the default rather than an empty tile.
    static func customSymbol(_ iconName: String?) -> String? {
        guard let name = LibrarySymbolCatalog.normalizedName(iconName),
              NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        else { return nil }
        return name
    }

    /// Groups draw the filled variant, as the folder always has. Some symbols gained a fill only in
    /// a later release (`globe.fill` is macOS 26), so the outline stands in when the fill is missing.
    static func groupSymbol(_ iconName: String?) -> String {
        filledVariant(of: customSymbol(iconName) ?? defaultGroupSymbol)
    }

    static func filledVariant(of name: String) -> String {
        let filled = name + ".fill"
        return NSImage(systemSymbolName: filled, accessibilityDescription: nil) == nil ? name : filled
    }

    static func connectionImage(type: DatabaseType, iconName: String?) -> Image {
        guard let symbol = customSymbol(iconName) else { return type.iconImage }
        return Image(systemName: symbol)
    }

    /// A template image for AppKit surfaces, which tint it themselves.
    static func connectionNSImage(type: DatabaseType, iconName: String?, accessibilityDescription: String?) -> NSImage? {
        let name = customSymbol(iconName) ?? type.iconName
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) {
            return symbol
        }
        /// Copied before it is touched. `NSImage(named:)` returns the one cached instance for that
        /// asset, so setting `isTemplate` on it rewrites the image every other consumer holds.
        guard let asset = NSImage(named: name)?.copy() as? NSImage else { return nil }
        asset.isTemplate = true
        asset.accessibilityDescription = accessibilityDescription
        return asset
    }

    static func groupNSImage(iconName: String?, color: ConnectionColor, pointSize: CGFloat = 13) -> NSImage? {
        ConnectionLibrarySymbols.image(systemName: groupSymbol(iconName), color: color, pointSize: pointSize)
    }
}

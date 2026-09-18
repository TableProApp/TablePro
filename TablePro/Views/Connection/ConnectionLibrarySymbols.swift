//
//  ConnectionLibrarySymbols.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal enum ConnectionLibrarySymbols {
    internal static func folderImage(for color: ConnectionColor, pointSize: CGFloat = 13) -> NSImage? {
        image(systemName: "folder.fill", color: color, pointSize: pointSize)
    }

    internal static func tagImage(for color: ConnectionColor, pointSize: CGFloat = 12) -> NSImage? {
        image(systemName: "tag.fill", color: color, pointSize: pointSize)
    }

    internal static func tint(for color: ConnectionColor) -> NSColor {
        color.isDefault ? .secondaryLabelColor : NSColor(color.color)
    }

    internal static func image(systemName: String, color: ConnectionColor, pointSize: CGFloat = 13) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint(for: color)]))
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }
}

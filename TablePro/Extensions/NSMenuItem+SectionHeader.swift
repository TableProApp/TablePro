//
//  NSMenuItem+SectionHeader.swift
//  TablePro
//

import AppKit

internal extension NSMenuItem {
    /// `sectionHeader(title:)` is macOS 14. The fallback is what AppKit menus used before it:
    /// a disabled item carrying the title, which reads as a header and takes no clicks.
    static func sectionHeaderCompat(title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return .sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }
}

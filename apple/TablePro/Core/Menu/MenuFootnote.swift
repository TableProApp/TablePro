//
//  MenuFootnote.swift
//  TablePro
//

import AppKit

/// A disabled line of explanation at the foot of a menu, wrapped to a width the menu already has.
///
/// An `NSMenuItem` title is one line however long it is: a floor's reason, set as a plain title,
/// widened the Safe Mode list from 132pt to 585pt. An attributed title does keep its line breaks,
/// so the text is broken where TextKit would break it at `wrapWidth` and set as an attributed
/// title in the small menu font, which put the same list at 241pt over three lines. Measured on
/// macOS 27.
internal enum MenuFootnote {
    internal static let wrapWidth: CGFloat = 220

    internal static var font: NSFont {
        NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
    }

    internal static func item(_ text: String) -> NSMenuItem {
        let item = unwrappedItem(text)
        wrap(item)
        return item
    }

    /// A footnote that starts hidden: its text as a plain title, for `wrap(_:)` to lay out when
    /// it is first shown. Laying out the two hidden Manual Commit rows at launch cost 2 to 3 ms of
    /// main thread before the first window, for rows most sessions never show.
    internal static func unwrappedItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Sets the wrapped attributed title once; a footnote shown again keeps the lines it has.
    internal static func wrap(_ item: NSMenuItem) {
        guard item.attributedTitle == nil else { return }
        item.attributedTitle = NSAttributedString(
            string: wrapped(item.title, font: font, width: wrapWidth),
            attributes: [.font: font]
        )
    }

    /// The lines TextKit lays `text` out in at `width`, joined with line breaks.
    internal static func wrapped(_ text: String, font: NSFont, width: CGFloat) -> String {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let nsText = text as NSString
        var lines: [String] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: layoutManager.glyphRange(for: container)
        ) { _, _, _, glyphRange, _ in
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            lines.append(nsText.substring(with: characters).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines.joined(separator: "\n")
    }
}

//
//  StatefulToolbarItem.swift
//  TablePro
//

import AppKit

/// A toolbar item whose glyph reflects something that changes while the window is open.
///
/// `NSToolbarItem.image` is set once when the delegate vends the item, and `autovalidates` only
/// drives `isEnabled`, so a toggle built that way keeps its opening glyph forever. `validate()` is
/// the hook AppKit already calls on every validation pass, which is exactly when the glyph should
/// be reconsidered.
@MainActor
internal final class StatefulToolbarItem: NSToolbarItem {
    internal var symbolAccessibilityDescription: String?

    internal var symbolProvider: (@MainActor () -> String)? {
        didSet { applySymbol() }
    }

    private var appliedSymbol: String?

    override internal func validate() {
        super.validate()
        applySymbol()
    }

    private func applySymbol() {
        guard let symbol = symbolProvider?(), symbol != appliedSymbol else { return }
        appliedSymbol = symbol
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbolAccessibilityDescription)
    }
}

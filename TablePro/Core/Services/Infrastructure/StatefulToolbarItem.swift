//
//  StatefulToolbarItem.swift
//  TablePro
//

import AppKit

/// A glyph that follows something which changes while the window is open.
///
/// `NSToolbarItem.image` is set once when the delegate vends the item, and `autovalidates` only
/// drives `isEnabled`, so an item built that way keeps its opening glyph forever. `validate()` is
/// the hook AppKit already calls on every validation pass, which is exactly when the glyph should
/// be reconsidered. Two item classes need this and they have different superclasses, so the part
/// they share lives here rather than in either of them.
@MainActor
internal struct ToolbarSymbolSource {
    internal var accessibilityDescription: String?
    internal var provider: (@MainActor () -> String)?

    private var applied: String?

    /// Nil when the symbol has not changed, so a validation pass that decided nothing costs no
    /// image lookup and no redraw.
    internal mutating func pendingImage() -> NSImage? {
        guard let symbol = provider?(), symbol != applied else { return nil }
        applied = symbol
        return NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
    }
}

@MainActor
internal final class StatefulToolbarItem: NSToolbarItem {
    internal var symbolAccessibilityDescription: String? {
        get { symbolSource.accessibilityDescription }
        set { symbolSource.accessibilityDescription = newValue }
    }

    internal var symbolProvider: (@MainActor () -> String)? {
        get { symbolSource.provider }
        set {
            symbolSource.provider = newValue
            applySymbol()
        }
    }

    /// The words an item draws beside its glyph, for the centred pair that names the connection
    /// and the container. Re-read on the same validation pass as the symbol, so switching database
    /// repoints the title through the channel that already exists rather than a second observer.
    internal var titleProvider: (@MainActor () -> String)? {
        didSet { applyTitle() }
    }

    private var symbolSource = ToolbarSymbolSource()

    override internal func validate() {
        super.validate()
        applySymbol()
        applyTitle()
    }

    private func applySymbol() {
        guard let pending = symbolSource.pendingImage() else { return }
        image = pending
    }

    private func applyTitle() {
        guard let resolved = titleProvider?(), resolved != title else { return }
        title = resolved
    }
}

/// The safe-mode chooser: one of six levels, and the current one has to be readable without
/// opening the menu. `NSMenuToolbarItem` is the toolbar control that opens a menu, and the glyph
/// tracks the level through the validation pass `MainWindowToolbar.observeItemState` triggers.
@MainActor
internal final class SafeModeToolbarItem: NSMenuToolbarItem {
    internal var levelProvider: (@MainActor () -> SafeModeLevel)? {
        didSet { applyLevel() }
    }

    private var symbolSource = ToolbarSymbolSource()
    private var appliedLevel: SafeModeLevel?

    override internal func validate() {
        super.validate()
        applyLevel()
    }

    /// The tooltip carries the level's name because the glyph alone cannot: `lock` and
    /// `lock.open` differ by a few pixels, and VoiceOver reads no image at all.
    private func applyLevel() {
        guard let level = levelProvider?() else { return }
        symbolSource.provider = { level.iconName }
        symbolSource.accessibilityDescription = level.displayName
        if let pending = symbolSource.pendingImage() {
            image = pending
        }
        guard level != appliedLevel else { return }
        appliedLevel = level
        toolTip = String(format: String(localized: "Safe Mode: %@"), level.displayName)
    }
}

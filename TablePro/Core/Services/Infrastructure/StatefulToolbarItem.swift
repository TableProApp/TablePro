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

/// A glyph that is not always a symbol, such as an engine logo from the asset catalog. The key
/// names what the image shows, so a validation pass that changed nothing builds no image.
@MainActor
internal struct ToolbarGlyph {
    internal let key: String
    internal let image: @MainActor () -> NSImage?
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

    /// Leaves the overflow entry alone: the toolbar has not assigned its own yet, and reading
    /// `menuFormRepresentation` before then materializes AppKit's default one, which keeps neither
    /// the key equivalent nor the validation mapping.
    internal var glyphProvider: (@MainActor () -> ToolbarGlyph)? {
        didSet {
            appliedGlyphKey = nil
            guard let glyph = glyphProvider?() else { return }
            appliedGlyphKey = glyph.key
            image = glyph.image()
        }
    }

    private var symbolSource = ToolbarSymbolSource()
    private var appliedGlyphKey: String?

    override internal func validate() {
        super.validate()
        applySymbol()
        refreshGlyph()
        applyTitle()
    }

    /// An overflowed item survives only as its menu entry, so the entry takes the new glyph too.
    internal func refreshGlyph() {
        guard let glyph = glyphProvider?(), glyph.key != appliedGlyphKey else { return }
        appliedGlyphKey = glyph.key
        let resolved = glyph.image()
        image = resolved
        menuFormRepresentation?.setInformativeImage(resolved)
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

/// A toolbar control that opens a menu and answers for its own enablement.
///
/// It carries no action on purpose: given one, AppKit splits the control into a body that sends
/// the action and a separate chevron that opens the menu, so a click on the body opens nothing.
/// And `NSToolbarItem`'s own `validate()` only sends `validateToolbarItem(_:)` for an item that
/// has an action, so the toolbar's predicate for this identifier would never be consulted and the
/// control would stay live over a session that had gone. It asks on the validation pass instead,
/// which is also the one channel measured to keep reaching an item while it is hidden.
@MainActor
internal class StatefulMenuToolbarItem: NSMenuToolbarItem {
    internal var isEnabledProvider: (@MainActor () -> Bool)?

    override internal func validate() {
        super.validate()
        guard let isEnabledProvider else { return }
        isEnabled = isEnabledProvider()
    }
}

/// The safe-mode chooser: one of six levels, and the current one has to be readable without
/// opening the menu. `NSMenuToolbarItem` is the toolbar control that opens a menu, and the glyph
/// tracks the level through the validation pass `MainWindowToolbar.observeItemState` triggers.
@MainActor
internal final class SafeModeToolbarItem: StatefulMenuToolbarItem {
    /// The level and the floor under it, read on the same validation pass as the enablement, which
    /// is also the one pass measured to keep reaching an item while it is hidden. A floor that
    /// comes and goes without moving the level, Agent mode over a connection the user already set
    /// stricter than Alert, still changes the tooltip.
    internal var statusProvider: (@MainActor () -> SafeModeStatus)? {
        didSet { applyStatus() }
    }

    private var symbolSource = ToolbarSymbolSource()
    private var appliedStatus: SafeModeStatus?

    override internal func validate() {
        super.validate()
        applyStatus()
    }

    private func applyStatus() {
        guard let status = statusProvider?() else { return }
        let level = status.level
        symbolSource.provider = { level.iconName }
        symbolSource.accessibilityDescription = level.displayName
        if let pending = symbolSource.pendingImage() {
            image = pending
        }
        guard status != appliedStatus else { return }
        appliedStatus = status
        toolTip = status.toolTip
    }
}

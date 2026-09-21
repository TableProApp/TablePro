//
//  MainWindowToolbar+Validation.swift
//  TablePro
//

import AppKit

extension MainWindowToolbar: NSToolbarItemValidation {
    /// Listed exhaustively so a new state has to choose a side instead of inheriting "alive".
    ///
    /// `.connecting` counts because the health monitor writes it on every reconnect attempt, and
    /// the window keeps showing the session's tabs and rows throughout. Graying the whole toolbar
    /// out for the length of a backoff would dim every control for a blip that repairs itself.
    static func hasLiveSession(_ state: ToolbarConnectionState) -> Bool {
        switch state {
        case .connected, .connecting:
            return true
        case .disconnected, .error:
            return false
        }
    }

    /// Every item answers from `ToolbarContextResolver`, which decides with no window and no
    /// session, so the answer a test pins is the answer the titlebar draws.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        ToolbarContextResolver.isEnabled(item.itemIdentifier, context: validationContext())
    }
}

/// The connection window's toolbar, which tells its delegate where a validation pass starts and
/// ends so the pass can be answered from one context.
///
/// Measured on macOS 27: AppKit's own passes, the ones a window update runs, go through
/// `validateVisibleItems()`, so this override brackets them as well as the ones the app asks for.
/// There is no delegate callback for either edge of a pass, which is why this is a subclass.
@MainActor
internal final class ContextValidatedToolbar: NSToolbar {
    override internal func validateVisibleItems() {
        guard let owner = delegate as? MainWindowToolbar else {
            super.validateVisibleItems()
            return
        }
        owner.withinValidationPass { super.validateVisibleItems() }
    }
}

/// AppKit validates toolbar overflow entries as menu items rather than visible toolbar items, so
/// `validateToolbarItem(_:)` never sees them and every entry it does not answer for stays enabled.
/// A hand-written selector list here only covered three of the twelve actions, which left Refresh,
/// New Tab, Open Quickly, Export, Database, Results and Dashboard live in the overflow menu of a
/// narrow window while the same buttons were disabled on a wide one, and clicking one did nothing.
/// The mapping now comes from the factory that built the item, so it cannot fall behind again.
///
/// The Actions pull-down never reaches here. Its entries carry no target, so AppKit resolves them
/// through the responder chain to the window's controller, and that is the one validator they get.
extension MainWindowToolbar: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let itemIdentifier = itemIdentifier(forMenuFormAction: menuItem.action) else { return true }
        return ToolbarContextResolver.isEnabled(itemIdentifier, context: validationContext())
    }
}

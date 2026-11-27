//
//  ConnectionEditorToolbar.swift
//  TablePro
//

import AppKit

// Only the separator that tracks the sidebar divider, so the title sits over the detail column. The split view
// is a child of the window's content, not the content itself, so the separator names it instead of relying
// on `.sidebarTrackingSeparator` finding it.
@MainActor
final class ConnectionEditorToolbar: NSObject, NSToolbarDelegate {
    static let separatorIdentifier = NSToolbarItem.Identifier("com.TablePro.connectionEditor.sidebarSeparator")

    private weak var splitView: NSSplitView?

    init(splitView: NSSplitView) {
        self.splitView = splitView
        super.init()
    }

    func makeToolbar() -> NSToolbar {
        // AppKit mirrors item changes into every toolbar sharing an identifier, and each editor window has its own.
        let toolbar = NSToolbar(identifier: "com.TablePro.connectionEditor.toolbar.\(UUID().uuidString)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.separatorIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard identifier == Self.separatorIdentifier, let splitView else { return nil }
        return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)
    }
}

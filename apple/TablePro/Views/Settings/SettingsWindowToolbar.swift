//
//  SettingsWindowToolbar.swift
//  TablePro
//

import AppKit
import Combine

// The System Settings toolbar: a back/forward navigation group pinned to the leading edge of the
// detail region, then the current page title in bold. AppKit draws the sidebar/detail tracking
// separator. Forward stays disabled (a NavigationStack is back-only), which matches the reference's
// idle state. No centered window title.
@MainActor
internal final class SettingsWindowToolbar: NSObject, NSToolbarDelegate {
    private static let backForward = NSToolbarItem.Identifier("com.TablePro.settings.backForward")
    private static let pageTitle = NSToolbarItem.Identifier("com.TablePro.settings.title")

    private let model: SettingsNavigationModel
    private weak var backItem: NSToolbarItem?
    private weak var titleField: NSTextField?
    private var cancellable: AnyCancellable?

    internal init(model: SettingsNavigationModel) {
        self.model = model
        super.init()
        cancellable = model.objectWillChange.sink { [weak self] in
            // objectWillChange fires before the value updates; read it on the next runloop turn.
            Task { @MainActor in self?.sync() }
        }
    }

    internal func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "com.TablePro.settings.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, Self.backForward, Self.pageTitle, .flexibleSpace]
    }

    internal func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    internal func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.backForward:
            let back = chevron(id: "com.TablePro.settings.back", symbol: "chevron.backward", label: String(localized: "Back"))
            back.target = self
            back.action = #selector(goBack(_:))
            back.isEnabled = model.canGoBack
            backItem = back

            let forward = chevron(id: "com.TablePro.settings.forward", symbol: "chevron.forward", label: String(localized: "Forward"))
            forward.isEnabled = false

            // isNavigational pins the pair to the leading edge of the detail region (Finder/Safari/System Settings).
            let group = NSToolbarItemGroup(itemIdentifier: identifier)
            group.label = String(localized: "Navigation")
            group.paletteLabel = String(localized: "Navigation")
            group.subitems = [back, forward]
            group.isNavigational = true
            return group

        case Self.pageTitle:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let field = NSTextField(labelWithString: model.currentTitle)
            field.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .bold)
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            item.view = field
            item.visibilityPriority = .high
            titleField = field
            return item

        default:
            return nil
        }
    }

    private func chevron(id: String, symbol: String, label: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(id))
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.isBordered = true
        // Enablement is driven by canGoBack; without this AppKit auto-enables Back because its
        // target responds to the action, so it would never dim at a pane root.
        item.autovalidates = false
        return item
    }

    private func sync() {
        titleField?.stringValue = model.currentTitle
        backItem?.isEnabled = model.canGoBack
    }

    @objc private func goBack(_ sender: Any?) {
        model.goBack()
    }
}

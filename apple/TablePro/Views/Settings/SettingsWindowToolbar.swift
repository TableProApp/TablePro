import AppKit

// Back and Forward as one navigational group, so AppKit draws the window title right after it
// (System Settings). A pane that filters its own list gets a search item at the trailing edge.
@MainActor
internal final class SettingsWindowToolbar: NSObject, NSToolbarDelegate {
    internal static let navigationIdentifier = NSToolbarItem.Identifier("com.TablePro.settings.backForward")
    internal static let keyboardSearchIdentifier = NSToolbarItem.Identifier("com.TablePro.settings.keyboardSearch")
    internal static let extensionsFilterIdentifier = NSToolbarItem.Identifier("com.TablePro.settings.extensionsFilter")
    private static let filterWidth: CGFloat = 180

    internal var onBack: (() -> Void)?
    internal var onForward: (() -> Void)?

    private weak var toolbar: NSToolbar?
    private weak var navigationGroup: NSToolbarItemGroup?
    private var canGoBack = false
    private var canGoForward = false
    private var filterPane: SettingsPane?
    private var filter: SettingsPaneFilter?

    internal func makeToolbar() -> NSToolbar {
        // AppKit mirrors an insert or remove into every toolbar sharing the identifier, and a closed
        // window's toolbar can outlive it with a different item count, which throws.
        let toolbar = NSToolbar(identifier: "com.TablePro.settings.toolbar.\(UUID().uuidString)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
        self.toolbar = toolbar
        return toolbar
    }

    internal var isBackEnabled: Bool {
        navigationGroup?.subitems.first?.isEnabled ?? canGoBack
    }

    internal var isForwardEnabled: Bool {
        navigationGroup?.subitems.last?.isEnabled ?? canGoForward
    }

    internal func update(canGoBack: Bool, canGoForward: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        applyNavigationState()
    }

    // Inserted and removed by identifier, only when the wanted item differs, so a navigation never flickers it.
    internal func showFilter(for pane: SettingsPane, filter: SettingsPaneFilter?) {
        let wanted = filter == nil ? nil : Self.filterIdentifier(for: pane)
        filterPane = wanted == nil ? nil : pane
        self.filter = wanted == nil ? nil : filter
        guard let toolbar else { return }
        for (index, item) in toolbar.items.enumerated().reversed()
            where Self.isFilterIdentifier(item.itemIdentifier) && item.itemIdentifier != wanted {
            toolbar.removeItem(at: index)
        }
        guard let wanted else { return }
        if let item = toolbar.items.first(where: { $0.itemIdentifier == wanted }) as? NSSearchToolbarItem {
            syncField(item.searchField)
        } else {
            toolbar.insertItem(withItemIdentifier: wanted, at: toolbar.items.count)
        }
    }

    // Returns false when the current pane has no filter, so Find falls back to the sidebar search.
    internal func focusFilter() -> Bool {
        guard let filterPane,
              let identifier = Self.filterIdentifier(for: filterPane),
              let item = toolbar?.items.first(where: { $0.itemIdentifier == identifier }) as? NSSearchToolbarItem
        else { return false }
        item.beginSearchInteraction()
        return true
    }

    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, Self.navigationIdentifier, .flexibleSpace]
    }

    internal func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Self.keyboardSearchIdentifier, Self.extensionsFilterIdentifier]
    }

    internal func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.navigationIdentifier:
            return makeNavigationGroup()
        case Self.keyboardSearchIdentifier:
            return makeFilterItem(
                identifier: identifier,
                placeholder: String(localized: "Search Shortcuts"),
                accessibilityIdentifier: "shortcut-search"
            )
        case Self.extensionsFilterIdentifier:
            return makeFilterItem(
                identifier: identifier,
                placeholder: String(localized: "Filter"),
                accessibilityIdentifier: "extensions-filter"
            )
        default:
            return nil
        }
    }

    private func makeNavigationGroup() -> NSToolbarItemGroup {
        let back = String(localized: "Back")
        let forward = String(localized: "Forward")
        let images = [
            NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: back),
            NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: forward),
        ].compactMap { $0 }
        let group = NSToolbarItemGroup(
            itemIdentifier: Self.navigationIdentifier,
            images: images,
            selectionMode: .momentary,
            labels: [back, forward],
            target: self,
            action: #selector(navigate(_:))
        )
        group.isNavigational = true
        group.label = String(localized: "Navigation")
        group.paletteLabel = String(localized: "Navigation")
        // Enablement comes from history; autovalidation would enable both because the target answers the action.
        group.autovalidates = false
        for item in group.subitems {
            item.autovalidates = false
        }
        navigationGroup = group
        applyNavigationState()
        return group
    }

    private func applyNavigationState() {
        guard let subitems = navigationGroup?.subitems, subitems.count == 2 else { return }
        subitems[0].isEnabled = canGoBack
        subitems[1].isEnabled = canGoForward
        subitems[0].toolTip = Self.toolTip(String(localized: "Back"), action: .navigateBack)
        subitems[1].toolTip = Self.toolTip(String(localized: "Forward"), action: .navigateForward)
    }

    private static func toolTip(_ title: String, action: ShortcutAction) -> String {
        guard let key = AppSettingsManager.shared.keyboard.shortcut(for: action) else { return title }
        return String(format: String(localized: "%@ (%@)"), title, key.displayString)
    }

    @objc private func navigate(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup else { return }
        switch group.selectedIndex {
        case 0: onBack?()
        case 1: onForward?()
        default: break
        }
    }

    private func makeFilterItem(
        identifier: NSToolbarItem.Identifier,
        placeholder: String,
        accessibilityIdentifier: String
    ) -> NSSearchToolbarItem {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(filterChanged(_:))
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.widthAnchor.constraint(lessThanOrEqualToConstant: Self.filterWidth).isActive = true
        syncField(field)

        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.searchField = field
        item.preferredWidthForSearchField = Self.filterWidth
        item.label = placeholder
        return item
    }

    private func syncField(_ field: NSSearchField) {
        let query = filter?.query ?? ""
        if field.stringValue != query {
            field.stringValue = query
        }
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        guard let filter, filter.query != sender.stringValue else { return }
        filter.query = sender.stringValue
    }

    private static func filterIdentifier(for pane: SettingsPane) -> NSToolbarItem.Identifier? {
        switch pane {
        case .keyboard: keyboardSearchIdentifier
        case .plugins: extensionsFilterIdentifier
        default: nil
        }
    }

    private static func isFilterIdentifier(_ identifier: NSToolbarItem.Identifier) -> Bool {
        identifier == keyboardSearchIdentifier || identifier == extensionsFilterIdentifier
    }
}

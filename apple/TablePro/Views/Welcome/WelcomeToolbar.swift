//
//  WelcomeToolbar.swift
//  TablePro
//

import AppKit
import Combine
import TableProConnectionLibrary

extension NSToolbarItem.Identifier {
    static let welcomeNewConnection = NSToolbarItem.Identifier("welcome-toolbar-new-connection")
    static let welcomeNewGroup = NSToolbarItem.Identifier("welcome-toolbar-new-group")
    static let welcomeViewOptions = NSToolbarItem.Identifier("welcome-toolbar-view-options")
    static let welcomeSearch = NSToolbarItem.Identifier("welcome-toolbar-search")
}

// AppKit on purpose: SwiftUI's bridged toolbar and `.searchable` cost the Welcome window's first
// frame about 100 ms of main-thread time, more than anything else in it.
@MainActor
internal final class WelcomeToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    internal static let toolbarIdentifier = NSToolbar.Identifier("com.TablePro.welcome.toolbar")

    private let viewModel: WelcomeViewModel
    private weak var newConnectionItem: NSToolbarItem?
    private weak var viewOptionsItem: NSMenuToolbarItem?
    private(set) weak var searchItem: NSSearchToolbarItem?
    private(set) var viewOptionsSymbol = ToolbarSymbols.filter()
    // `suggestionsDelegate` is weak.
    private var tagSuggestions: AnyObject?
    private var cancellables: Set<AnyCancellable> = []

    internal init(viewModel: WelcomeViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    internal func install(in window: NSWindow) {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        observeViewModel()
    }

    internal func beginSearch() {
        searchItem?.beginSearchInteraction()
    }

    private func observeViewModel() {
        viewModel.$searchText
            .sink { [weak self] text in
                guard let field = self?.searchItem?.searchField, field.stringValue != text else { return }
                field.stringValue = text
            }
            .store(in: &cancellables)

        viewModel.$tagFilter
            .map(\.isActive)
            .removeDuplicates()
            .sink { [weak self] isActive in
                self?.showViewOptionsSymbol(ToolbarSymbols.filter(isActive: isActive))
            }
            .store(in: &cancellables)

        // The hop off the settings write keeps the item from changing part way through it.
        viewModel.services.appEvents.keyboardSettingsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                newConnectionItem?.toolTip = Self.newConnectionToolTip
            }
            .store(in: &cancellables)
    }

    // MARK: - NSToolbarDelegate

    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .welcomeNewConnection, .welcomeNewGroup, .welcomeViewOptions, .flexibleSpace, .welcomeSearch]
    }

    internal func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    internal func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .welcomeNewConnection:
            let item = makeButton(
                itemIdentifier,
                label: String(localized: "New Connection"),
                symbol: "plus",
                action: #selector(newConnection(_:))
            )
            item.toolTip = Self.newConnectionToolTip
            newConnectionItem = item
            return item
        case .welcomeNewGroup:
            return makeButton(
                itemIdentifier,
                label: String(localized: "New Group"),
                symbol: "folder.badge.plus",
                action: #selector(newGroup(_:))
            )
        case .welcomeViewOptions:
            return makeViewOptionsItem(itemIdentifier)
        case .welcomeSearch:
            return makeSearchItem(itemIdentifier)
        default:
            return nil
        }
    }

    private static var newConnectionToolTip: String {
        AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "New Connection"), for: .newConnection)
    }

    private func makeButton(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    private func makeViewOptionsItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        let label = String(localized: "View Options")
        item.label = label
        item.paletteLabel = label
        item.toolTip = String(localized: "Sort and filter connections")
        item.image = NSImage(systemSymbolName: viewOptionsSymbol, accessibilityDescription: label)
        item.showsIndicator = true
        let menu = NSMenu(title: label)
        menu.delegate = self
        item.menu = menu
        viewOptionsItem = item
        return item
    }

    private func makeSearchItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: "Search")
        item.paletteLabel = String(localized: "Search")
        let field = item.searchField
        field.placeholderString = String(localized: "Search Connections")
        // The view model debounces, as it did for `.searchable`, so every keystroke goes through.
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.stringValue = viewModel.searchText
        field.delegate = self
        field.target = self
        field.action = #selector(searchFieldChanged(_:))
        field.setAccessibilityIdentifier("welcome-toolbar-search")
        if #available(macOS 15.0, *) {
            let suggestions = WelcomeTagSuggestions(viewModel: viewModel)
            field.suggestionsDelegate = suggestions
            tagSuggestions = suggestions
        }
        searchItem = item
        return item
    }

    private func showViewOptionsSymbol(_ symbol: String) {
        guard symbol != viewOptionsSymbol else { return }
        viewOptionsSymbol = symbol
        viewOptionsItem?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: String(localized: "View Options")
        )
    }

    // MARK: - Actions

    @objc private func newConnection(_ sender: Any?) {
        WindowOpener.shared.openConnectionForm()
    }

    @objc private func newGroup(_ sender: Any?) {
        viewModel.requestNewGroup(parentId: nil, movingConnectionIds: [])
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        viewModel.searchText = sender.stringValue
    }

    @objc private func sortBy(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? LibrarySortMode else { return }
        viewModel.setSortMode(mode)
    }

    @objc private func toggleTagFilter(_ sender: NSMenuItem) {
        guard let tagId = sender.representedObject as? UUID else { return }
        viewModel.setTagFilter(tagId, isOn: sender.state != .on)
    }

    @objc private func matchTags(_ sender: NSMenuItem) {
        guard let match = sender.representedObject as? LibraryTagMatch else { return }
        viewModel.tagMatch = match
    }

    @objc private func clearTagFilters(_ sender: Any?) {
        viewModel.clearTagFilters()
    }

    // MARK: - NSSearchFieldDelegate

    internal func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        viewModel.focusList(selectFirstRow: true)
        return true
    }

    // MARK: - NSMenuDelegate

    internal func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeaderCompat(title: String(localized: "Sort By")))
        for option in WelcomeSortOption.allCases {
            menu.addItem(menuEntry(
                option.title,
                action: #selector(sortBy(_:)),
                value: option.mode,
                isOn: option.mode == viewModel.sortMode
            ))
        }

        let tags = viewModel.availableTags
        guard !tags.isEmpty else { return }
        let activeIds = Set(viewModel.tagFilterIds)
        menu.addItem(.separator())
        menu.addItem(.sectionHeaderCompat(title: String(localized: "Filter by Tag")))
        for tag in tags {
            let entry = menuEntry(
                tag.name,
                action: #selector(toggleTagFilter(_:)),
                value: tag.id,
                isOn: activeIds.contains(tag.id)
            )
            entry.image = ConnectionLibrarySymbols.tagImage(for: tag.color)
            menu.addItem(entry)
        }

        let filter = viewModel.tagFilter
        if filter.offersMatch {
            menu.addItem(.separator())
            menu.addItem(.sectionHeaderCompat(title: String(localized: "Match")))
            for match in LibraryTagMatch.allCases {
                menu.addItem(menuEntry(
                    Self.title(for: match),
                    action: #selector(matchTags(_:)),
                    value: match,
                    isOn: match == filter.match
                ))
            }
        }
        if filter.isActive {
            menu.addItem(.separator())
            menu.addItem(menuEntry(String(localized: "Clear Filters"), action: #selector(clearTagFilters(_:)), value: nil, isOn: false))
        }
    }

    internal static func title(for match: LibraryTagMatch) -> String {
        switch match {
        case .any: return String(localized: "Any Selected Tag")
        case .all: return String(localized: "All Selected Tags")
        }
    }

    private func menuEntry(_ title: String, action: Selector, value: Any?, isOn: Bool) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.representedObject = value
        entry.state = isOn ? .on : .off
        return entry
    }
}

// Picking a tag while typing is the one way to reach a tag filter without opening View Options.
@available(macOS 15.0, *)
@MainActor
internal final class WelcomeTagSuggestions: NSTextSuggestionsDelegate {
    internal typealias SuggestionItemType = UUID

    private weak var viewModel: WelcomeViewModel?

    internal init(viewModel: WelcomeViewModel) {
        self.viewModel = viewModel
    }

    internal func suggestions(for text: String) -> ItemResponse {
        let tags = viewModel?.tagSuggestions(matching: text) ?? []
        guard !tags.isEmpty else { return ItemResponse() }
        let items = tags.map { tag -> Item in
            var item = Item(representedValue: tag.id, title: tag.name)
            item.image = ConnectionLibrarySymbols.tagImage(for: tag.color)
            return item
        }
        return ItemResponse(itemSections: [ItemSection(title: String(localized: "Tags"), items: items)])
    }

    internal func textField(_ textField: NSTextField, provideUpdatedSuggestions responseHandler: @escaping (ItemResponse) -> Void) {
        responseHandler(suggestions(for: textField.stringValue))
    }

    // A tag name typed into the field would filter by text as well as by the tag.
    internal func textField(_ textField: NSTextField, textCompletionFor item: Item) -> String? {
        nil
    }

    internal func textField(_ textField: NSTextField, didSelect item: Item) {
        viewModel?.applyTagSuggestion(item.representedValue)
    }
}

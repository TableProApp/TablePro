//
//  DataFileWindowController.swift
//  TablePro
//

import AppKit
import Combine

extension NSToolbarItem.Identifier {
    static let dataFileAddRow = NSToolbarItem.Identifier("com.TablePro.dataFile.addRow")
    static let dataFileDeleteRows = NSToolbarItem.Identifier("com.TablePro.dataFile.deleteRows")
    static let dataFileColumns = NSToolbarItem.Identifier("com.TablePro.dataFile.columns")
    static let dataFileFilters = NSToolbarItem.Identifier("com.TablePro.dataFile.filters")
    static let dataFileSearch = NSToolbarItem.Identifier("com.TablePro.dataFile.search")
    static let dataFileInspector = NSToolbarItem.Identifier("com.TablePro.dataFile.inspector")
}

@MainActor
final class DataFileWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    static let tabbingIdentifier = "com.TablePro.DataFileDocument"
    static let frameAutosaveName = "com.TablePro.DataFileWindow"

    private weak var dataFileDocument: DataFileDocument?
    private let splitController: DataFileSplitViewController
    private var searchItem: NSSearchToolbarItem?
    private var cancellables: Set<AnyCancellable> = []

    init(document: DataFileDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 560, height: 360)
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.dataFile)

        splitController = DataFileSplitViewController(document: document)
        dataFileDocument = document
        super.init(window: window)
        shouldCloseDocument = true
        window.delegate = self
        window.contentViewController = splitController
        window.setContentSize(NSSize(width: 1_100, height: 680))
        window.center()
        if let pinnedSize = ScreenshotEnvironment.windowSize {
            let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            window.setFrame(
                visibleFrame.map { ScreenshotEnvironment.pinnedFrame(size: pinnedSize, in: $0) }
                    ?? NSRect(origin: window.frame.origin, size: pinnedSize),
                display: false
            )
        } else if let autosaveName = SplitViewAutosaveName.current(Self.frameAutosaveName) {
            windowFrameAutosaveName = autosaveName
        }

        let toolbar = NSToolbar(identifier: "com.TablePro.DataFileToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        document.controller.$searchText
            .removeDuplicates()
            .sink { [weak self] text in
                guard let field = self?.searchItem?.searchField, field.stringValue != text else { return }
                field.stringValue = text
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        dataFileDocument?.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        (contentViewController as? DataFileSplitViewController)?.dismissTransientUI()
    }

    func focusSearchField() {
        searchItem?.beginSearchInteraction()
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .dataFileAddRow:
            return makeItem(itemIdentifier, label: String(localized: "Add Row"), symbol: "plus",
                            action: #selector(DataFileSplitViewController.addRow(_:)))
        case .dataFileDeleteRows:
            return makeItem(itemIdentifier, label: String(localized: "Delete"), symbol: "minus",
                            action: #selector(DataFileSplitViewController.dataFileDeleteSelectedRows(_:)))
        case .dataFileFilters:
            return makeItem(itemIdentifier, label: String(localized: "Filters"), symbol: "line.3.horizontal.decrease.circle",
                            action: #selector(DataFileSplitViewController.toggleFilterBar(_:)))
        case .dataFileInspector:
            return makeItem(itemIdentifier, label: String(localized: "Inspector"), symbol: "sidebar.trailing",
                            action: #selector(DataFileSplitViewController.toggleInspector(_:)))
        case .dataFileColumns:
            return makeColumnsItem(itemIdentifier)
        case .dataFileSearch:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: "Search")
            item.paletteLabel = String(localized: "Search All Columns")
            item.searchField.placeholderString = String(localized: "Search All Columns")
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged(_:))
            item.searchField.setAccessibilityIdentifier("data-file-search")
            item.preferredWidthForSearchField = 220
            searchItem = item
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.dataFileAddRow, .dataFileDeleteRows, .dataFileColumns, .flexibleSpace, .dataFileFilters,
         .dataFileSearch, .dataFileInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        guard let controller = dataFileDocument?.controller else { return }
        controller.searchText = sender.stringValue
        controller.scheduleQuery()
    }

    private func makeColumnsItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        let label = String(localized: "Columns")
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: label)
        item.showsIndicator = true
        let menu = NSMenu()
        menu.delegate = splitController
        item.menu = menu
        return item
    }

    private func makeItem(
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
        item.action = action
        item.target = nil
        item.isBordered = true
        return item
    }
}

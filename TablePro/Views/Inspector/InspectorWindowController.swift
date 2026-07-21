//
//  InspectorWindowController.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension NSToolbarItem.Identifier {
    static let inspectorAddRow = NSToolbarItem.Identifier("com.TablePro.inspector.addRow")
    static let inspectorDeleteRows = NSToolbarItem.Identifier("com.TablePro.inspector.deleteRows")
    static let inspectorToggleFilter = NSToolbarItem.Identifier("com.TablePro.inspector.toggleFilter")
    static let inspectorColumns = NSToolbarItem.Identifier("com.TablePro.inspector.columns")
}

@MainActor
final class ColumnTypeAssignment: NSObject {
    let column: Int
    let type: InspectorColumnType?

    init(column: Int, type: InspectorColumnType?) {
        self.column = column
        self.type = type
        super.init()
    }
}

@MainActor
final class InspectorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate {
    private weak var documentRef: NSDocument?

    init(nsDocument: NSDocument, inspectorDocument: any InspectorDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 480, height: 320)
        window.tabbingIdentifier = "com.TablePro.CSVDocument"
        window.tabbingMode = .preferred
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("main-inspector")

        super.init(window: window)
        documentRef = nsDocument
        shouldCloseDocument = true
        window.delegate = self

        let viewController = InspectorViewController(nsDocument: nsDocument, inspectorDocument: inspectorDocument)
        window.contentViewController = viewController
        window.setContentSize(NSSize(width: 1_000, height: 640))
        window.center()
        if let url = nsDocument.fileURL {
            windowFrameAutosaveName = "com.TablePro.CSVInspector.\(url.absoluteString)"
        } else {
            windowFrameAutosaveName = "com.TablePro.CSVInspector.untitled"
        }

        let toolbar = NSToolbar(identifier: "com.TablePro.CSVInspectorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        documentRef?.undoManager
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .inspectorAddRow:
            return makeItem(
                identifier: itemIdentifier,
                label: String(localized: "Add Row"),
                symbol: "plus",
                action: #selector(InspectorViewController.inspectorAddRow(_:))
            )
        case .inspectorDeleteRows:
            return makeItem(
                identifier: itemIdentifier,
                label: String(localized: "Delete"),
                symbol: "minus",
                action: #selector(InspectorViewController.inspectorDeleteSelectedRows(_:))
            )
        case .inspectorToggleFilter:
            return makeItem(
                identifier: itemIdentifier,
                label: String(localized: "Filter"),
                symbol: "line.3.horizontal.decrease.circle",
                action: #selector(InspectorViewController.toggleInspectorFilter(_:))
            )
        case .inspectorColumns:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: "Columns")
            item.paletteLabel = String(localized: "Columns")
            item.toolTip = String(localized: "Columns")
            item.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: String(localized: "Columns"))
            item.showsIndicator = true
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.inspectorAddRow, .inspectorDeleteRows, .inspectorColumns, .flexibleSpace, .inspectorToggleFilter]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.inspectorAddRow, .inspectorDeleteRows, .inspectorColumns, .inspectorToggleFilter, .flexibleSpace, .space]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let addItem = NSMenuItem(
            title: String(localized: "Add Column…"),
            action: #selector(InspectorViewController.inspectorAddColumn(_:)),
            keyEquivalent: ""
        )
        addItem.target = nil
        menu.addItem(addItem)

        guard let inspector = documentRef as? (any InspectorDocument) else { return }
        let columns = inspector.columnNames
        guard !columns.isEmpty else { return }
        menu.addItem(.separator())
        for (index, name) in columns.enumerated() {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let type = inspector.displayedType(forColumn: index)
            item.image = NSImage(
                systemSymbolName: InspectorColumnMenuBuilder.typeSymbol(type),
                accessibilityDescription: nil
            )
            item.submenu = columnSubmenu(forColumn: index, currentType: type)
            menu.addItem(item)
        }
    }

    private func columnSubmenu(forColumn index: Int, currentType: InspectorColumnType) -> NSMenu {
        let submenu = NSMenu()
        let items = InspectorColumnMenuBuilder.structureItems(
            forColumn: index,
            currentType: currentType,
            deleteColumns: [index]
        )
        for item in items {
            submenu.addItem(item)
        }
        return submenu
    }

    private func makeItem(
        identifier: NSToolbarItem.Identifier,
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

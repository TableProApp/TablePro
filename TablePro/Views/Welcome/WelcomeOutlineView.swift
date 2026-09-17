//
//  WelcomeOutlineView.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProConnectionLibrary

internal extension NSPasteboard.PasteboardType {
    static let welcomeLibraryRow = NSPasteboard.PasteboardType("com.tablepro.welcome.library-row")
}

internal enum WelcomeDragToken {
    internal static func encode(_ row: LibraryRowID) -> String? {
        switch row {
        case .group(let id):
            return "group|\(id.uuidString)"
        case .connection(let id, let section) where section.acceptsSavedConnections:
            return "connection|\(section.rawValue)|\(id.uuidString)"
        default:
            return nil
        }
    }

    internal static func decode(_ token: String) -> LibraryDragItem? {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "group":
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
            return .group(id)
        case "connection":
            guard parts.count == 3,
                  let section = LibrarySectionKind(rawValue: parts[1]),
                  section.acceptsSavedConnections,
                  let id = UUID(uuidString: parts[2]) else { return nil }
            return .connection(id, section: section)
        default:
            return nil
        }
    }
}

internal final class WelcomeOutlineItem: NSObject {
    internal let row: LibraryRowID
    internal var children: [WelcomeOutlineItem] = []

    internal init(row: LibraryRowID) {
        self.row = row
    }

    internal var isSection: Bool {
        if case .section = row { return true }
        return false
    }
}

internal final class WelcomeOutlineCellView: RenamableSidebarCellView<WelcomeOutlineRow> {
    internal var renameSymbolName = "folder"

    override internal var editorSymbolName: String { renameSymbolName }
    override internal var editorAccessibilityIdentifier: String { "welcome-rename-field" }
}

@MainActor
internal protocol WelcomeOutlineKeyHandling: AnyObject {
    var canDeleteSelection: Bool { get }
    func performPrimaryAction()
    func performDelete()
    func clearSelection()
}

internal final class WelcomeNSOutlineView: SidebarOutlineView, NSMenuItemValidation {
    internal weak var keyHandler: (any WelcomeOutlineKeyHandling)?

    override internal func insertNewline(_ sender: Any?) {
        keyHandler?.performPrimaryAction()
    }

    override internal func cancelOperation(_ sender: Any?) {
        keyHandler?.clearSelection()
    }

    override internal func deleteBackward(_ sender: Any?) {
        keyHandler?.performDelete()
    }

    override internal func deleteForward(_ sender: Any?) {
        keyHandler?.performDelete()
    }

    @objc internal func delete(_ sender: Any?) {
        keyHandler?.performDelete()
    }

    internal func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(delete(_:)) else { return true }
        return keyHandler?.canDeleteSelection ?? false
    }
}

internal struct WelcomeOutlineView: NSViewRepresentable {
    internal let viewModel: WelcomeViewModel
    internal let revision: Int

    internal func makeCoordinator() -> WelcomeOutlineCoordinator {
        WelcomeOutlineCoordinator(viewModel: viewModel)
    }

    internal func makeNSView(context: Context) -> NSScrollView {
        let outlineView = WelcomeNSOutlineView()
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "WelcomeConnectionColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .matchSystem,
                style: .inset
            )
        )
        outlineView.setAccessibilityIdentifier("welcome-connection-list")
        outlineView.setAccessibilityLabel(String(localized: "Connections"))
        outlineView.registerForDraggedTypes([.welcomeLibraryRow])
        outlineView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(WelcomeOutlineCoordinator.handleDoubleClick)
        outlineView.keyHandler = context.coordinator

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outlineView.menu = menu

        context.coordinator.attach(outlineView: outlineView)
        return scrollView
    }

    internal func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(revision: revision)
    }
}

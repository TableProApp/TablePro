//
//  ERDiagramMenu.swift
//  TablePro
//

import AppKit

enum ERDiagramMenuTarget: Equatable {
    case table(String)
    case column(table: String, column: String)
    case edge(UUID)
    case canvas(CGPoint)
}

enum ERDiagramMenuCommand: Equatable {
    case openTable(String)
    case showStructure(String)
    case copyName(String)
    case addColumn(table: String)
    case renameColumn(table: String, column: String)
    case dropColumn(table: String, column: String)
    case addForeignKey(table: String, column: String)
    case dropForeignKey(UUID)
    case newTable(at: CGPoint)
    case refresh
}

struct ERDiagramMenuEntry: Equatable {
    let title: String
    let command: ERDiagramMenuCommand

    init(_ title: String, _ command: ERDiagramMenuCommand) {
        self.title = title
        self.command = command
    }
}

// A context menu leaves out what the engine cannot do rather than dimming it (HIG, Context menus), so
// the sections arrive already decided and nothing here validates.
@MainActor
enum ERDiagramMenuBuilder {
    static func menu(sections: [[ERDiagramMenuEntry]], target: AnyObject, action: Selector) -> NSMenu? {
        let filled = sections.filter { !$0.isEmpty }
        guard !filled.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, section) in filled.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            for entry in section {
                let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
                item.target = target
                item.representedObject = ERDiagramMenuCommandBox(entry.command)
                menu.addItem(item)
            }
        }
        return menu
    }
}

// An enum with associated values does not survive `representedObject`'s trip through Objective-C.
final class ERDiagramMenuCommandBox: NSObject {
    let command: ERDiagramMenuCommand

    init(_ command: ERDiagramMenuCommand) {
        self.command = command
    }
}

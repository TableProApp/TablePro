//
//  HighlightMenuBuilder.swift
//  TablePro
//

import AppKit
import TableProPluginKit

@MainActor
enum HighlightMenuBuilder {
    struct CellContext {
        let columnName: String
        let columnOccurrence: Int
        let columnType: ColumnType?
        let value: PluginCellValue
        let existingRules: [HighlightRule]
    }

    struct Actions {
        let apply: (HighlightRule) -> Void
        let remove: (HighlightRule) -> Void
        let showRules: () -> Void
    }

    static func quickRule(
        columnName: String,
        columnOccurrence: Int,
        columnType: ColumnType?,
        value: PluginCellValue,
        target: HighlightTarget,
        color: HighlightColor
    ) -> HighlightRule? {
        switch value {
        case .null:
            return HighlightRule(
                columnName: columnName,
                columnOccurrence: columnOccurrence,
                filterOperator: .isNull,
                color: color,
                target: target
            )
        case .text(let text) where text.isEmpty:
            return HighlightRule(
                columnName: columnName,
                columnOccurrence: columnOccurrence,
                filterOperator: .isEmpty,
                color: color,
                target: target
            )
        case .text(let text) where HighlightCondition.readsAsNullLiteral(text, columnType: columnType):
            return nil
        case .text(let text):
            return HighlightRule(
                columnName: columnName,
                columnOccurrence: columnOccurrence,
                filterOperator: .equal,
                value: text,
                color: color,
                target: target
            )
        case .bytes:
            return nil
        }
    }

    static func sectionTitle(for rule: HighlightRule) -> String {
        let condition = HighlightRuleDescription.condition(
            of: rule,
            valueLimit: HighlightRuleDescription.menuValueLimit
        )
        switch rule.target {
        case .row:
            return String(format: String(localized: "Rows Where %@"), condition)
        case .cell:
            return String(format: String(localized: "Cells Where %@"), condition)
        }
    }

    static func menuItem(for context: CellContext, actions: Actions) -> NSMenuItem? {
        let templates = HighlightTarget.allCases.compactMap { target in
            quickRule(
                columnName: context.columnName,
                columnOccurrence: context.columnOccurrence,
                columnType: context.columnType,
                value: context.value,
                target: target,
                color: .yellow
            )
        }
        guard !templates.isEmpty else { return nil }

        let submenu = NSMenu()
        var existingMatches: [HighlightRule] = []
        for template in templates {
            let existing = context.existingRules.first { $0.hasSameCondition(as: template) }
            if let existing { existingMatches.append(existing) }
            submenu.addItem(.sectionHeaderCompat(title: sectionTitle(for: template)))
            submenu.addItem(paletteItem(for: template, existing: existing, actions: actions))
        }

        submenu.addItem(.separator())
        if !existingMatches.isEmpty {
            submenu.addItem(ClosureMenuTarget.item(title: String(localized: "Remove Highlight")) {
                existingMatches.forEach(actions.remove)
            })
        }
        submenu.addItem(ClosureMenuTarget.item(title: String(localized: "Highlight Rules…"), action: actions.showRules))

        let item = NSMenuItem(title: String(localized: "Highlight"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    private static func paletteItem(
        for template: HighlightRule,
        existing: HighlightRule?,
        actions: Actions
    ) -> NSMenuItem {
        let colors = HighlightColor.allCases
        let apply: (Int) -> Void = { index in
            guard colors.indices.contains(index) else { return }
            var rule = existing ?? template
            rule.color = colors[index]
            rule.isEnabled = true
            actions.apply(rule)
        }

        let palette: NSMenu
        if #available(macOS 14.0, *) {
            /// Clicking the item already selected deselects it and reports an empty selection,
            /// measured on macOS 27: `performActionForItem(at:)` on the preselected colour leaves
            /// `selectedItems` empty and fires the handler. That used to reach a remove arm, so
            /// clicking the colour a rule already had deleted the rule. Removing is what **Remove
            /// Highlight** is for, so an empty selection changes nothing.
            let menu = NSMenu.palette(
                colors: colors.map(\.systemColor),
                titles: colors.map(\.displayName)
            ) { menu in
                guard let selected = menu.selectedItems.first,
                      let index = menu.items.firstIndex(of: selected) else { return }
                apply(index)
            }
            menu.selectionMode = .selectOne
            if let marked = Self.markedColor(for: existing),
               let index = colors.firstIndex(of: marked), index < menu.items.count {
                menu.selectedItems = [menu.items[index]]
            }
            palette = menu
        } else {
            /// `NSMenu.palette` is macOS 14. The fallback is a plain menu of the same colours,
            /// each drawn with its own swatch and check-marked when it is the rule's colour, so
            /// the same choice is offered a row at a time instead of as one strip.
            let menu = NSMenu()
            for (index, color) in colors.enumerated() {
                let entry = ClosureMenuTarget.item(title: color.displayName) { apply(index) }
                entry.setInformativeImage(Self.swatch(for: color.systemColor))
                entry.state = Self.markedColor(for: existing) == color ? .on : .off
                menu.addItem(entry)
            }
            palette = menu
        }

        let item = NSMenuItem(title: sectionTitle(for: template), action: nil, keyEquivalent: "")
        item.submenu = palette
        return item
    }

    /// The color the cell is actually painted, which is nothing when the rule is switched off.
    /// Ticking a disabled rule's color claimed a highlight the grid was not drawing.
    static func markedColor(for existing: HighlightRule?) -> HighlightColor? {
        guard let existing, existing.isEnabled else { return nil }
        return existing.color
    }

    private static func swatch(for color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}

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
            submenu.addItem(.sectionHeader(title: sectionTitle(for: template)))
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
        let palette = NSMenu.palette(
            colors: colors.map(\.systemColor),
            titles: colors.map(\.displayName)
        ) { menu in
            let selected = menu.selectedItems.compactMap { menu.items.firstIndex(of: $0) }
            guard let index = selected.first, colors.indices.contains(index) else {
                if let existing { actions.remove(existing) }
                return
            }
            var rule = existing ?? template
            rule.color = colors[index]
            rule.isEnabled = true
            actions.apply(rule)
        }
        palette.selectionMode = .selectOne
        if let existing, let index = colors.firstIndex(of: existing.color), index < palette.items.count {
            palette.selectedItems = [palette.items[index]]
        }

        let item = NSMenuItem(title: sectionTitle(for: template), action: nil, keyEquivalent: "")
        item.submenu = palette
        return item
    }
}

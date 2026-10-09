//
//  TreeOutlineMenu.swift
//  TablePro
//

import Foundation

internal enum TreeOutlineMenuCommand: Int, CaseIterable, Sendable {
    case copyText
    case openLink
    case copyLink
    case copyValue
    case copyKeyPath
    case copyKey
    case expandAll
    case collapseAll

    var title: String {
        switch self {
        case .copyText: return String(localized: "Copy")
        case .openLink: return String(localized: "Open Link")
        case .copyLink: return String(localized: "Copy Link")
        case .copyValue: return String(localized: "Copy Value")
        case .copyKeyPath: return String(localized: "Copy Key Path")
        case .copyKey: return String(localized: "Copy Key")
        case .expandAll: return String(localized: "Expand All")
        case .collapseAll: return String(localized: "Collapse All")
        }
    }
}

internal enum TreeOutlineMenuEntry: Equatable, Sendable {
    case command(TreeOutlineMenuCommand)
    case separator
}

internal enum TreeOutlineMenuLayout {
    static func entries<Node: FilterableTreeNode>(
        for rows: [Node],
        hasTextSelection: Bool = false
    ) -> [TreeOutlineMenuEntry] {
        var copies: [TreeOutlineMenuCommand] = []
        if TreeSelectionText.hasValue(in: rows) { copies.append(.copyValue) }
        if rows.contains(where: { !$0.keyPath.isEmpty }) { copies.append(.copyKeyPath) }
        if rows.contains(where: { $0.key != nil }) { copies.append(.copyKey) }

        let groups: [[TreeOutlineMenuCommand]] = [
            hasTextSelection ? [.copyText] : [],
            link(of: rows) == nil ? [] : [.openLink, .copyLink],
            copies,
            rows.contains(where: \.isContainer) ? [.expandAll, .collapseAll] : []
        ]
        return Array(
            groups
                .filter { !$0.isEmpty }
                .map { $0.map(TreeOutlineMenuEntry.command) }
                .joined(separator: [.separator])
        )
    }

    static func link<Node: FilterableTreeNode>(of rows: [Node]) -> URL? {
        guard rows.count == 1, case .link(let url) = rows[0].rowContent.decoration else { return nil }
        return url
    }
}

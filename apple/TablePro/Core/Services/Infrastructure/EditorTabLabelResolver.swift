//
//  EditorTabLabelResolver.swift
//  TablePro
//

import Foundation

// Two databases often hold the same object name, so a tab is qualified with its container only when another
// open tab would draw the same label: a bar of qualified names is harder to read. Only a tab naming an object
// is qualified, since `mydb.Server Dashboard` names nothing. Resolved per render, never written into the title,
// because it depends on what else is open and would otherwise outlive that sibling in persistence.
internal enum EditorTabLabelResolver {
    internal struct Label: Equatable {
        // Drawn on the strip and read by VoiceOver.
        internal let text: String
        // The tooltip, which has room for the container whether or not the text needed it.
        internal let description: String
        // The container the text leaves out, for a line beside it such as the Control-Tab detail.
        internal let container: String?

        internal init(text: String, description: String, container: String? = nil) {
            self.text = text
            self.description = description
            self.container = container
        }
    }

    internal static func resolve(tabs: [QueryTab], target: ContainerSwitchTarget?) -> [UUID: Label] {
        var containers: [UUID: String] = [:]
        var containersByTitle: [String: Set<String>] = [:]

        for tab in tabs {
            let container = tab.tableContext.tableName == nil
                ? ""
                : WorkspaceAnchoring.containerName(of: tab, target: target) ?? ""
            containers[tab.id] = container
            containersByTitle[tab.title, default: []].insert(container)
        }

        return tabs.reduce(into: [:]) { result, tab in
            if let database = checkedDatabase(of: tab) {
                result[tab.id] = Label(
                    text: tab.title,
                    description: String(format: String(localized: "%@: %@"), tab.title, database),
                    container: database
                )
                return
            }
            let container = containers[tab.id] ?? ""
            // Two tabs sharing a title inside one container are not told apart by naming it.
            let isAmbiguous = (containersByTitle[tab.title]?.count ?? 0) > 1
            let qualified = qualify(tab.title, with: container)
            let text = isAmbiguous ? qualified : tab.title
            result[tab.id] = Label(
                text: text,
                description: qualified,
                container: container.isEmpty || text.hasPrefix("\(container).") ? nil : container
            )
        }
    }

    // Every Table Health tab carries the same title, one per database, so the database is said beside it.
    private static func checkedDatabase(of tab: QueryTab) -> String? {
        guard tab.tabType == .tableHealth, !tab.tableContext.databaseName.isEmpty else { return nil }
        return tab.tableContext.databaseName
    }

    // A schema engine already titles a table outside the default schema `reporting.orders`.
    private static func qualify(_ title: String, with container: String) -> String {
        guard !container.isEmpty, !title.hasPrefix("\(container).") else { return title }
        return "\(container).\(title)"
    }
}

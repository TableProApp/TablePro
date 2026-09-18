//
//  EditorTabLabelResolver.swift
//  TablePro
//

import Foundation

/// What the editor tab strip draws on each tab, and what it says about that tab on hover and to
/// VoiceOver.
///
/// A tab's title names the object it shows, and two databases of one connection routinely hold the
/// same object name, so browsing both leaves two tabs reading `role_ability` with nothing to tell
/// them apart. The container qualifies the label when, and only when, another open tab would draw
/// the same one. That is what DataGrip does across schemas and VS Code across folders: a name that
/// is already unique stays short, because a bar of qualified names is harder to read, not easier.
///
/// Only a tab that names an object is ever qualified. `container.name` reads as a path to that
/// object, which a Server Dashboard or a Users & Roles tab is not: those are server work that
/// happens to have been opened from a database, and `mydb.Server Dashboard` names nothing.
///
/// The tooltip carries the container either way, since hovering has no width budget. The
/// accessibility label stays on the drawn text, so what VoiceOver reads is what is on screen; when
/// two tabs really do collide the drawn text is already qualified, and both channels say so.
///
/// Resolved for rendering rather than written into `QueryTab.title`, because qualification is a
/// function of what else is open: baked into the tab it would outlive the sibling that caused it,
/// follow the tab into persistence, and come back out of Recently Closed long after it meant
/// anything.
internal enum EditorTabLabelResolver {
    internal struct Label: Equatable {
        /// What the strip draws, and what VoiceOver reads.
        internal let text: String
        /// What hovering says.
        internal let description: String

        internal init(text: String, description: String) {
            self.text = text
            self.description = description
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
            /// More than one container behind one title is the whole test. Two tabs sharing a title
            /// inside one container are not told apart by naming that container, so they stay bare.
            let isAmbiguous = (containersByTitle[tab.title]?.count ?? 0) > 1
            let qualified = qualify(tab.title, with: containers[tab.id])
            result[tab.id] = Label(
                text: isAmbiguous ? qualified : tab.title,
                description: qualified
            )
        }
    }

    /// On an engine whose containers are schemas, a table tab outside the default schema is already
    /// titled `reporting.orders`, so prefixing the container again would read `reporting.reporting.orders`.
    private static func qualify(_ title: String, with container: String?) -> String {
        guard let container, !container.isEmpty, !title.hasPrefix("\(container).") else { return title }
        return "\(container).\(title)"
    }
}

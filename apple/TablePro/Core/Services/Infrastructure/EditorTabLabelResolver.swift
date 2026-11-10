//
//  EditorTabLabelResolver.swift
//  TablePro
//

import Foundation

/// How a tab that shows a table or view names it. Any other tab keeps its title in both styles.
internal enum EditorTabTitleStyle: Equatable {
    /// The object's name alone, as it was opened: `orders`, or `reporting.orders` outside the
    /// engine's default schema.
    case name
    /// The name, the database and the connection: `orders@shop_demo (Shop Demo)`, for a reader
    /// moving between several databases and connections who wants each tab to say where its rows
    /// come from without hovering it.
    case location(connectionName: String)

    internal init(showsLocation: Bool, connectionName: String) {
        self = showsLocation ? .location(connectionName: connectionName) : .name
    }
}

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
/// anything. A located title is resolved here too: it is a preference, so turning it off has to
/// bring every open tab back to its name at once, and a saved tab must never carry it.
internal enum EditorTabLabelResolver {
    internal struct Label: Equatable {
        /// What the strip draws, and what VoiceOver reads.
        internal let text: String
        /// What hovering says.
        internal let description: String
        /// The object's glyph, drawn before the text. Only a located title carries one: it is long
        /// and mostly the same from tab to tab, so the glyph is what still tells a table from a
        /// view at a glance.
        internal let symbolName: String?

        internal init(text: String, description: String, symbolName: String? = nil) {
            self.text = text
            self.description = description
            self.symbolName = symbolName
        }
    }

    internal static func resolve(
        tabs: [QueryTab],
        target: ContainerSwitchTarget?,
        style: EditorTabTitleStyle = .name
    ) -> [UUID: Label] {
        var titles: [UUID: String] = [:]
        var containers: [UUID: String] = [:]
        var containersByTitle: [String: Set<String>] = [:]

        for tab in tabs {
            let title = title(of: tab, style: style)
            let container = qualifyingContainer(of: tab, target: target, style: style)
            titles[tab.id] = title
            containers[tab.id] = container
            containersByTitle[title, default: []].insert(container)
        }

        return tabs.reduce(into: [:]) { result, tab in
            let title = titles[tab.id] ?? tab.title
            /// More than one container behind one title is the whole test. Two tabs sharing a title
            /// inside one container are not told apart by naming that container, so they stay bare.
            let isAmbiguous = (containersByTitle[title]?.count ?? 0) > 1
            let qualified = qualify(title, with: containers[tab.id])
            result[tab.id] = Label(
                text: isAmbiguous ? qualified : title,
                description: qualified,
                symbolName: symbolName(of: tab, style: style)
            )
        }
    }

    /// `orders@shop_demo (Shop Demo)`. A part with no value is left out rather than drawn empty,
    /// so a tab whose database is not known reads `orders (Shop Demo)`. The `@` joins two
    /// identifiers, so it is not localized; the parentheses go through the catalog, where a locale
    /// can set them its own way.
    internal static func locationTitle(object: String, database: String, connectionName: String) -> String {
        let located = database.isEmpty ? object : "\(object)@\(database)"
        guard !connectionName.isBlank else { return located }
        return String(format: String(localized: "%1$@ (%2$@)"), located, connectionName)
    }

    /// The object's title is reused rather than rebuilt from its name, because it already carries
    /// the schema exactly when the engine needs it named.
    private static func title(of tab: QueryTab, style: EditorTabTitleStyle) -> String {
        guard case let .location(connectionName) = style, showsObject(tab) else { return tab.title }
        return locationTitle(
            object: tab.title,
            database: tab.tableContext.databaseName,
            connectionName: connectionName
        )
    }

    private static func symbolName(of tab: QueryTab, style: EditorTabTitleStyle) -> String? {
        guard case .location = style, showsObject(tab) else { return nil }
        return TableRowLogic.iconName(for: tab.tableContext.resolvedObjectKind())
    }

    /// A located title already names its database, so on an engine whose containers are databases
    /// qualifying it again would read `shop_demo.orders@shop_demo`. A schema still qualifies it,
    /// since the title leaves the default schema out.
    private static func qualifyingContainer(
        of tab: QueryTab,
        target: ContainerSwitchTarget?,
        style: EditorTabTitleStyle
    ) -> String {
        guard tab.tableContext.tableName != nil,
              let container = WorkspaceAnchoring.containerName(of: tab, target: target) else { return "" }
        if case .location = style, showsObject(tab), container == tab.tableContext.databaseName {
            return ""
        }
        return container
    }

    private static func showsObject(_ tab: QueryTab) -> Bool {
        tab.tabType == .table && tab.tableContext.tableName != nil
    }

    /// On an engine whose containers are schemas, a table tab outside the default schema is already
    /// titled `reporting.orders`, so prefixing the container again would read `reporting.reporting.orders`.
    private static func qualify(_ title: String, with container: String?) -> String {
        guard let container, !container.isEmpty, !title.hasPrefix("\(container).") else { return title }
        return "\(container).\(title)"
    }
}

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

// Two databases often hold the same object name, so a tab is qualified with its container only when another
// open tab would draw the same label: a bar of qualified names is harder to read. Only a tab naming an object
// is qualified, since `mydb.Server Dashboard` names nothing. Resolved per render, never written into the title,
// because it depends on what else is open and would otherwise outlive that sibling in persistence. A located
// title is resolved here too: it is a preference, so turning it off brings every open tab back to its name at
// once, and a saved tab never carries it.
internal enum EditorTabLabelResolver {
    internal struct Label: Equatable {
        // Drawn on the strip and read by VoiceOver.
        internal let text: String
        // The tooltip, which has room for the container whether or not the text needed it.
        internal let description: String
        /// The object's glyph, drawn before the text. In the standard icon style only a located
        /// title carries one: it is long and mostly the same from tab to tab, so the glyph is what
        /// still tells a table from a view at a glance. In the colorful style every tab showing an
        /// object or a query carries its kind's tinted glyph, which is the point of that style.
        internal let icon: ObjectIcon?
        /// A located title's short form, drawn when the whole title does not fit, and nil for every other
        /// title. The tab asks for the width of the whole title first; when the strip cannot give it, the
        /// connection goes, then the object gives way in its middle while `@database` stays whole, so the
        /// tab never loses the part that tells it from the same table in another database.
        internal let shortForm: ShortForm?

        internal var symbolName: String? { icon?.symbolName }
        // The container the text leaves out, for a line beside it such as the Control-Tab detail.
        internal let container: String?

        internal init(
            text: String,
            description: String,
            icon: ObjectIcon? = nil,
            shortForm: ShortForm? = nil,
            container: String? = nil
        ) {
            self.text = text
            self.description = description
            self.icon = icon
            self.shortForm = shortForm
            self.container = container
        }
    }

    /// `orders` and `@shop_demo` of `orders@shop_demo (Shop Demo)`. `database` is empty when the tab
    /// names no database.
    internal struct ShortForm: Equatable {
        internal let object: String
        internal let database: String
    }

    internal static func resolve(
        tabs: [QueryTab],
        target: ContainerSwitchTarget?,
        style: EditorTabTitleStyle = .name,
        iconStyle: ObjectIconStyle = .standard
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
            if let database = checkedDatabase(of: tab) {
                result[tab.id] = Label(
                    text: tab.title,
                    description: String(format: String(localized: "%@: %@"), tab.title, database),
                    icon: icon(of: tab, style: style, iconStyle: iconStyle),
                    container: database
                )
                return
            }
            let title = titles[tab.id] ?? tab.title
            let container = containers[tab.id] ?? ""
            // Two tabs sharing a title inside one container are not told apart by naming it.
            let isAmbiguous = (containersByTitle[title]?.count ?? 0) > 1
            let qualified = qualify(title, with: container)
            let text = isAmbiguous ? qualified : title
            result[tab.id] = Label(
                text: text,
                description: qualified,
                icon: icon(of: tab, style: style, iconStyle: iconStyle),
                shortForm: shortForm(of: tab, style: style, container: isAmbiguous ? container : nil),
                container: container.isEmpty || text.hasPrefix("\(container).") ? nil : container
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

    /// Qualified the way the whole title is, so a collision the location does not settle stays told apart.
    private static func shortForm(of tab: QueryTab, style: EditorTabTitleStyle, container: String?) -> ShortForm? {
        guard case .location = style, showsObject(tab) else { return nil }
        let database = tab.tableContext.databaseName
        return ShortForm(
            object: qualify(tab.title, with: container),
            database: database.isEmpty ? "" : "@\(database)"
        )
    }

    private static func icon(of tab: QueryTab, style: EditorTabTitleStyle, iconStyle: ObjectIconStyle) -> ObjectIcon? {
        switch iconStyle {
        case .standard:
            guard case .location = style, showsObject(tab) else { return nil }
            return ObjectIconProvider.icon(for: .relation(tab.tableContext.resolvedObjectKind()), style: .standard)
        case .colorful:
            return ObjectIconKind(tab: tab).map { ObjectIconProvider.icon(for: $0, style: .colorful) }
        }
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

    // Every Table Health tab carries the same title, one per database, so the database is said beside it.
    private static func checkedDatabase(of tab: QueryTab) -> String? {
        guard tab.tabType == .tableHealth, !tab.tableContext.databaseName.isEmpty else { return nil }
        return tab.tableContext.databaseName
    }

    // A schema engine already titles a table outside the default schema `reporting.orders`.
    private static func qualify(_ title: String, with container: String?) -> String {
        guard let container, !container.isEmpty, !title.hasPrefix("\(container).") else { return title }
        return "\(container).\(title)"
    }
}

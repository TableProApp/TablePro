import Foundation
import TableProPluginKit

@MainActor
final class PrivilegeNode {
    let scope: PluginPrivilegeScope
    let title: String
    let isExpandable: Bool

    private(set) var children: [PrivilegeNode]?
    private(set) var isLoading = false

    init(scope: PluginPrivilegeScope, title: String, isExpandable: Bool) {
        self.scope = scope
        self.title = title
        self.isExpandable = isExpandable
    }

    var hasLoadedChildren: Bool { children != nil }

    func beginLoading() {
        isLoading = true
    }

    func setChildren(_ children: [PrivilegeNode]) {
        self.children = children
        isLoading = false
    }

    static func make(for scope: PluginPrivilegeScope) -> PrivilegeNode {
        PrivilegeNode(
            scope: scope,
            title: title(for: scope),
            isExpandable: isExpandable(scope)
        )
    }

    private static func isExpandable(_ scope: PluginPrivilegeScope) -> Bool {
        switch scope {
        case .server, .column:
            false
        case .database, .schema, .table:
            true
        }
    }

    private static func title(for scope: PluginPrivilegeScope) -> String {
        switch scope {
        case .server:
            String(localized: "Server (all databases)")
        case let .database(name):
            name
        case let .schema(_, schema):
            schema
        case let .table(_, _, table):
            table
        case let .column(_, _, _, column):
            column
        }
    }
}

import Foundation
import TableProPluginKit

@MainActor
final class PrivilegeNode: NSObject {
    enum ChildrenAvailability {
        case available
        case restrictedToCurrentDatabase
        case none
    }

    let scope: PluginPrivilegeScope
    let childrenAvailability: ChildrenAvailability

    private(set) var children: [PrivilegeNode]?
    private(set) var isLoading = false
    private(set) var loadError: String?

    init(scope: PluginPrivilegeScope, childrenAvailability: ChildrenAvailability) {
        self.scope = scope
        self.childrenAvailability = childrenAvailability
        super.init()
    }

    var title: String { scope.displayName }
    var symbolName: String { scope.symbolName }
    var persistentKey: String { scope.persistentKey }
    var hasLoadedChildren: Bool { children != nil }

    var isExpandable: Bool {
        guard childrenAvailability == .available else { return false }
        guard let children else { return true }
        return !children.isEmpty
    }

    func beginLoading() {
        isLoading = true
        loadError = nil
    }

    func setChildren(_ children: [PrivilegeNode]) {
        self.children = children
        isLoading = false
        loadError = nil
    }

    func failLoading(_ error: String) {
        children = []
        isLoading = false
        loadError = error
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PrivilegeNode else { return false }
        return scope == other.scope
    }

    override var hash: Int {
        scope.hashValue
    }

    static func make(
        for scope: PluginPrivilegeScope,
        restrictsBrowsing: Bool,
        currentDatabase: String?
    ) -> PrivilegeNode {
        PrivilegeNode(
            scope: scope,
            childrenAvailability: availability(
                for: scope,
                restrictsBrowsing: restrictsBrowsing,
                currentDatabase: currentDatabase
            )
        )
    }

    private static func availability(
        for scope: PluginPrivilegeScope,
        restrictsBrowsing: Bool,
        currentDatabase: String?
    ) -> ChildrenAvailability {
        switch scope {
        case .server, .column:
            .none
        case .database, .schema, .table:
            if restrictsBrowsing, let database = scope.databaseName, database != currentDatabase {
                .restrictedToCurrentDatabase
            } else {
                .available
            }
        }
    }
}

import Foundation

public struct PathComponent: Hashable, Sendable {
    public let name: String
    public let scope: UUID?
    public let color: String?
    public let iconName: String?

    public init(name: String, scope: UUID?, color: String?, iconName: String? = nil) {
        self.name = name
        self.scope = scope
        self.color = color
        self.iconName = iconName
    }
}

public struct PathNode: Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let parentId: UUID?
    public let scope: UUID?
    /// Set only on nodes the resolver created, so a store styles only what it adds.
    public let color: String?
    public let iconName: String?

    public init(
        id: UUID,
        name: String,
        parentId: UUID?,
        scope: UUID?,
        color: String? = nil,
        iconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.scope = scope
        self.color = color
        self.iconName = iconName
    }
}

public enum PathTreeResolver {
    private struct ChildKey: Hashable {
        let parentId: UUID?
        let name: String
        let scope: UUID?
    }

    public static func resolve(
        _ paths: [[PathComponent]],
        existing: [PathNode],
        makeId: () -> UUID = UUID.init
    ) -> (created: [PathNode], leaves: [UUID?]) {
        var children: [ChildKey: UUID] = [:]
        for node in existing {
            let key = ChildKey(parentId: node.parentId, name: normalized(node.name), scope: node.scope)
            if children[key] == nil {
                children[key] = node.id
            }
        }

        var created: [PathNode] = []
        var leaves: [UUID?] = []
        for path in paths {
            var parentId: UUID?
            for component in path {
                let name = component.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let key = ChildKey(parentId: parentId, name: name.lowercased(), scope: component.scope)
                if let id = children[key] {
                    parentId = id
                    continue
                }
                let node = PathNode(
                    id: makeId(),
                    name: name,
                    parentId: parentId,
                    scope: component.scope,
                    color: component.color,
                    iconName: component.iconName
                )
                children[key] = node.id
                created.append(node)
                parentId = node.id
            }
            leaves.append(parentId)
        }
        return (created, leaves)
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

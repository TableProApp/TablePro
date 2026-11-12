//
//  SidebarServerObjectKind.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// An object kind a driver declares, such as MySQL events. The app reads it as an opaque descriptor and
// compares it by id alone, so a kind decoded from storage with no driver equals the declared one.
struct SidebarServerObjectKind: Sendable, Hashable {
    enum Scope: String, Sendable, Hashable, Codable {
        case container
        case database
    }

    let id: String
    let displayName: String
    let pluralDisplayName: String
    let iconName: String
    let scope: Scope

    init(id: String, displayName: String, pluralDisplayName: String, iconName: String, scope: Scope) {
        self.id = id
        self.displayName = displayName
        self.pluralDisplayName = pluralDisplayName
        self.iconName = iconName
        self.scope = scope
    }

    init(id: String) {
        self.init(id: id, displayName: id, pluralDisplayName: id, iconName: "shippingbox", scope: .container)
    }

    init(_ kind: PluginServerObjectKind) {
        let scope: Scope
        switch kind.scope {
        case .container: scope = .container
        case .database: scope = .database
        @unknown default: scope = .container
        }
        self.init(
            id: kind.id,
            displayName: kind.displayName,
            pluralDisplayName: kind.pluralDisplayName,
            iconName: kind.iconName,
            scope: scope
        )
    }

    static func == (lhs: SidebarServerObjectKind, rhs: SidebarServerObjectKind) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // Menu validation and every redraw ask, and a driver answers the same for its whole life.
    @MainActor private static let probed = NSMapTable<AnyObject, DeclaredKinds>.weakToStrongObjects()

    @MainActor
    static func declared(by driver: DatabaseDriver?) -> [SidebarServerObjectKind] {
        guard let driver else { return [] }
        if let known = probed.object(forKey: driver) {
            return known.kinds
        }
        var seen = Set<String>()
        let kinds = driver.serverObjectKinds
            .map(SidebarServerObjectKind.init)
            .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        probed.setObject(DeclaredKinds(kinds), forKey: driver)
        return kinds
    }

    private final class DeclaredKinds {
        let kinds: [SidebarServerObjectKind]

        init(_ kinds: [SidebarServerObjectKind]) {
            self.kinds = kinds
        }
    }
}

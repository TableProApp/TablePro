//
//  DatabaseDropRequest.swift
//  TablePro
//

import Foundation

struct DatabaseDropRequest: Identifiable, Equatable {
    static let maxListedNames = 10

    let id: String
    let targets: [DatabaseContainerRef]
    let entityName: String
    let entityNamePlural: String
    let dropsDependentObjects: Bool

    init(
        targets: [DatabaseContainerRef],
        entityName: String,
        entityNamePlural: String,
        dropsDependentObjects: Bool = false
    ) {
        self.targets = targets.sortedByName
        self.entityName = entityName
        self.entityNamePlural = entityNamePlural
        self.dropsDependentObjects = dropsDependentObjects
        self.id = self.targets.map(\.id).joined(separator: "\u{1}")
    }

    var kind: DatabaseContainerRef.Kind {
        targets.first?.kind ?? .database
    }

    var names: [String] {
        targets.map(\.name)
    }

    var isEmpty: Bool {
        targets.isEmpty
    }

    var title: String {
        guard targets.count != 1 else {
            return String(
                format: String(localized: "Drop %1$@ “%2$@”?"),
                entityName.lowercased(),
                targets[0].name
            )
        }
        return String(
            format: String(localized: "Drop %1$lld %2$@?"),
            targets.count,
            entityNamePlural.lowercased()
        )
    }

    var menuTitle: String {
        guard targets.count != 1 else {
            return String(format: String(localized: "Drop %1$@ “%2$@”…"), entityName, targets[0].name)
        }
        return String(format: String(localized: "Drop %1$lld %2$@…"), targets.count, entityNamePlural)
    }

    var confirmButtonTitle: String {
        guard targets.count != 1 else {
            return String(format: String(localized: "Drop %@"), entityName)
        }
        return String(format: String(localized: "Drop %1$lld %2$@"), targets.count, entityNamePlural)
    }

    var message: String {
        var lines: [String] = []
        if targets.count > 1 {
            lines.append(listedNames)
        }
        lines.append(String(localized: "All tables and data will be permanently deleted."))
        if dropsDependentObjects {
            lines.append(String(localized: "Objects that depend on them will be dropped too."))
        }
        return lines.joined(separator: "\n\n")
    }

    private var listedNames: String {
        let listed = names.prefix(Self.maxListedNames).joined(separator: ", ")
        let overflow = names.count - Self.maxListedNames
        guard overflow > 0 else { return listed }
        return listed + String(format: String(localized: ", and %lld more"), overflow)
    }
}

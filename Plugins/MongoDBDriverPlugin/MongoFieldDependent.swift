//
//  MongoFieldDependent.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

/// Something that reads a field by name, and would be left pointing at a path no document has, or
/// reading values meant for another field, once the field is renamed or removed.
enum MongoFieldDependent: Equatable {
    case index(name: String, field: String)
    case searchIndex(name: String, field: String)
    case view(name: String, field: String)

    /// Both names are checked. The old name stops matching the index the moment the first document
    /// moves, and the new name can meet a unique key or a text index's `language_override` that
    /// stops the write partway.
    static func index(of changes: [MongoFieldChange], among indexes: [MongoIndexSpec]) -> MongoFieldDependent? {
        for change in changes {
            for name in change.names {
                guard let index = indexes.first(where: { $0.reaches(name) }) else { continue }
                return .index(name: index.name, field: name)
            }
        }
        return nil
    }

    /// Both names, as for any other index. Search indexes build in the background, so nothing stops
    /// the write: an old name leaves the definition pointing at a path no document has, and a new
    /// name puts values under a mapping written for a different field.
    static func searchIndex(
        of changes: [MongoFieldChange],
        among searchIndexes: [MongoSearchIndex]
    ) -> MongoFieldDependent? {
        for change in changes {
            for name in change.names {
                guard let index = searchIndexes.first(where: { $0.mentions(name) }) else { continue }
                return .searchIndex(name: index.name, field: name)
            }
        }
        return nil
    }

    /// Only the old name counts. A view that reads the new name already expects the field there.
    static func view(
        of changes: [MongoFieldChange],
        among views: [MongoViewDefinition],
        collection: String
    ) -> MongoFieldDependent? {
        let dependents = MongoViewDefinition.dependents(of: collection, among: views)
        for change in changes {
            guard let view = dependents.first(where: { $0.readsField(change.source) }) else { continue }
            return .view(name: view.name, field: change.source)
        }
        return nil
    }

    /// The first of each kind, in the order the save checks them before writing.
    static func dependent(
        of changes: [MongoFieldChange],
        indexes: [MongoIndexSpec],
        searchIndexes: [MongoSearchIndex],
        views: [MongoViewDefinition],
        collection: String
    ) -> MongoFieldDependent? {
        index(of: changes, among: indexes)
            ?? searchIndex(of: changes, among: searchIndexes)
            ?? view(of: changes, among: views, collection: collection)
    }

    /// Why the save stops before writing, and what to do first.
    func refusal(collection: String) -> String {
        switch self {
        case .index(let name, let field):
            let drop = "\(MongoCollectionAccessor.expression(for: collection)).dropIndex(\(MongoScriptJson.jsonString(name)))"
            return String(
                format: String(localized: "Index %1$@ uses %2$@. Drop it first by running %3$@ in a query tab, then save again."),
                name, field, drop
            )
        case .searchIndex(let name, let field):
            return String(
                format: String(localized: "Search index %1$@ uses %2$@. Change or drop that search index first, then save again."),
                name, field
            )
        case .view(let name, let field):
            return String(
                format: String(localized: "View %1$@ reads %2$@. Change the view first, then save again."),
                name, field
            )
        }
    }

    /// Said once the statements ran, for one another client made while they did.
    func appearedDuringSave(collection: String) -> String {
        switch self {
        case .index(let name, let field):
            return String(
                format: String(localized: "The save ran, but index %1$@ on %2$@ was created while it did and uses %3$@. Check that it indexes the field you meant."),
                name, collection, field
            )
        case .searchIndex(let name, let field):
            return String(
                format: String(localized: "The save ran, but search index %1$@ on %2$@ was created while it did and uses %3$@. Check that it maps the field you meant."),
                name, collection, field
            )
        case .view(let name, let field):
            return String(
                format: String(localized: "The save ran, but view %1$@ was created while it did and reads %2$@. Change it to read the field where it is now."),
                name, field
            )
        }
    }
}

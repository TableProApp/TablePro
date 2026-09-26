//
//  MongoFieldChange.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

/// A Structure tab column edit, carried out on the documents of a collection.
///
/// A collection declares no columns: the Structure tab lists the fields its documents hold. A rename
/// is therefore `$rename` in every document that has the field, and a removal is `$unset` in every
/// document that has it. Each statement is one `updateMany` whose filter keeps every document atomic
/// and every run idempotent: a rename skips a document that already holds the new name, so nothing
/// is ever overwritten, and running the same statement again after a stop touches only the documents
/// it had not reached.
enum MongoFieldChange: Equatable, Sendable {
    case rename(from: String, to: String)
    case remove(String)

    init?(_ operation: PluginSchemaOperation) {
        switch operation {
        case .modifyColumn(let old, let new):
            guard old.name != new.name else { return nil }
            self = .rename(from: old.name, to: new.name)
        case .dropColumn(let column):
            self = .remove(column.name)
        default:
            return nil
        }
    }

    var source: String {
        switch self {
        case .rename(let from, _): return from
        case .remove(let name): return name
        }
    }

    var target: String? {
        switch self {
        case .rename(_, let to): return to
        case .remove: return nil
        }
    }

    var names: [String] {
        [source] + (target.map { [$0] } ?? [])
    }

    /// The filter of the statement, which is also the set of documents the server validates when
    /// the statement runs.
    var filterJson: String {
        let source = MongoScriptJson.jsonString(source)
        guard let target else { return "{\(source): {\"$exists\": true}}" }
        return "{\(source): {\"$exists\": true}, \(MongoScriptJson.jsonString(target)): {\"$exists\": false}}"
    }

    /// The `updateMany`, carrying the connection's write concern as its option when the connection
    /// sets one, so the save is acknowledged the way the user asked for.
    func statement(collection: String, writeConcern: MongoWriteConcern) -> String {
        let accessor = MongoCollectionAccessor.expression(for: collection)
        let source = MongoScriptJson.jsonString(source)
        let update = target.map { "{\"$rename\": {\(source): \(MongoScriptJson.jsonString($0))}}" }
            ?? "{\"$unset\": {\(source): \"\"}}"
        guard let concern = writeConcern.schemaChangeJson else {
            return "\(accessor).updateMany(\(filterJson), \(update))"
        }
        return "\(accessor).updateMany(\(filterJson), \(update), {\"writeConcern\": \(concern)})"
    }

    /// Why a column edit cannot be carried out on the documents, or nil when it can. Nil too for
    /// every operation that is not a column edit, so the collection's own refusals still answer.
    static func refusal(for operation: PluginSchemaOperation) -> String? {
        switch operation {
        case .modifyColumn(let old, let new):
            guard old.name != new.name, !changesMoreThanTheName(old, new) else {
                return String(localized: "A MongoDB field has no type, default or nullability to change. Only its name can change.")
            }
            return keyRefusal(old.name) ?? MongoFieldName.addressingRefusal(old.name)
                ?? keyRefusal(new.name) ?? MongoFieldName.addressingRefusal(new.name)
        case .dropColumn(let column):
            return keyRefusal(column.name) ?? MongoFieldName.addressingRefusal(column.name)
        default:
            return nil
        }
    }

    private static func changesMoreThanTheName(_ old: PluginColumnDefinition, _ new: PluginColumnDefinition) -> Bool {
        old.dataType != new.dataType || old.isNullable != new.isNullable
            || old.defaultValue != new.defaultValue || old.comment != new.comment
    }

    private static func keyRefusal(_ name: String) -> String? {
        guard name == MongoDBCollectionDDL.idField else { return nil }
        return String(localized: "_id cannot be renamed, removed or used as a new name. MongoDB keys every document by it.")
    }
}

enum MongoFieldName {
    /// Why an update cannot name this field, or nil when it can.
    ///
    /// `$rename` and `$unset` read a dot as a path into an embedded document and refuse a leading
    /// `$`, so a literal key spelled either way cannot be reached by name. A NUL cannot be carried in
    /// a BSON key, and `__proto__` vanishes from the statement's object literal in the shell, which
    /// turns `$unset` into a write that matches and changes nothing.
    static func addressingRefusal(_ name: String) -> String? {
        if name.isEmpty {
            return String(localized: "A MongoDB field needs a name.")
        }
        if name.hasPrefix("$") || name.contains(".") {
            return String(
                format: String(localized: "MongoDB cannot address a field named %@. A field name cannot start with $ or contain a dot."),
                name
            )
        }
        if name.unicodeScalars.contains("\u{0}") {
            return String(localized: "A MongoDB field name cannot contain a NUL character.")
        }
        if name == "__proto__" {
            return String(
                format: String(localized: "The shell would reorder or drop a field named %@. Choose another name."),
                name
            )
        }
        return nil
    }
}

/// The field edits of one save, in the order their statements run.
struct MongoFieldChangePlan: Equatable, Sendable {
    let changes: [MongoFieldChange]
    let refusal: String?

    /// Each statement runs on its own, so a field named by two edits of one save would be read by
    /// the second after the first had already moved it: `a` to `b` then `b` to `c` carries `a`'s
    /// values on to `c`, and a swap overwrites nothing and completes nothing. Such a save is refused
    /// before anything is read.
    init(operations: [PluginSchemaOperation]) {
        let changes = operations.compactMap(MongoFieldChange.init)
        self.changes = changes
        self.refusal = Self.sharedNameRefusal(changes)
    }

    var isEmpty: Bool { changes.isEmpty }

    var renames: [(from: String, to: String)] {
        changes.compactMap { change in
            guard let target = change.target else { return nil }
            return (change.source, target)
        }
    }

    private static func sharedNameRefusal(_ changes: [MongoFieldChange]) -> String? {
        var seen = Set<String>()
        for name in changes.flatMap(\.names) where !seen.insert(name).inserted {
            return String(
                format: String(localized: "%@ is changed twice in this save. Save one change to it at a time."),
                name
            )
        }
        return nil
    }
}

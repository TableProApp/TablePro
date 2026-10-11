//
//  MongoFieldChangeAssessment.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

/// Whether a save's field edits can run against the collection as the catalog describes it, and the
/// validator the collection has to carry for them to.
///
/// Everything here is read from the catalog and nothing from the documents, so it is cheap enough
/// for SQL Preview. What only the documents can show is `MongoFieldDataProbe`'s, on Save.
struct MongoFieldChangeAssessment: Equatable, Sendable {
    let refusal: String?
    /// The validator after the edits, when they change it. It runs first, as a `collMod`.
    let rewrittenValidatorJson: String?
    /// The validator the statements are checked against: the rewritten one when there is one.
    let effectiveValidatorJson: String?

    /// Every check the catalog can answer, in the order the reads come in: the collection's kind
    /// decides whether it has indexes to list at all, since `listIndexes` on a view fails with
    /// CommandNotSupportedOnView and on a missing collection with NamespaceNotFound.
    static func kindRefusal(_ info: MongoCollectionInfo) -> String? {
        if info.name.hasPrefix("system.") {
            return String(
                format: String(localized: "%@ is a system collection. Its fields cannot be renamed or removed."),
                info.name
            )
        }
        switch info.kind {
        case .collection:
            return nil
        case .missing:
            return String(format: String(localized: "Collection %@ no longer exists."), info.name)
        case .view:
            return String(
                format: String(localized: "%@ is a view. Rename or remove the field in the collection it reads."),
                info.name
            )
        case .timeseries:
            return String(
                format: String(localized: "%@ is a time series collection. MongoDB cannot rename or remove its fields."),
                info.name
            )
        case .other(let type):
            return String(
                format: String(localized: "%1$@ is a collection of type %2$@. Its fields cannot be renamed or removed."),
                info.name, type
            )
        }
    }

    static func assess(
        _ changes: [MongoFieldChange],
        info: MongoCollectionInfo,
        indexes: [MongoIndexSpec],
        searchIndexes: [MongoSearchIndex],
        views: [MongoViewDefinition]
    ) -> MongoFieldChangeAssessment {
        if let refusal = kindRefusal(info)
            ?? cappedRefusal(changes, info: info)
            ?? MongoFieldDependent.index(of: changes, among: indexes)?.refusal(collection: info.name)
            ?? MongoFieldDependent.searchIndex(of: changes, among: searchIndexes)?.refusal(collection: info.name)
            ?? encryptionRefusal(changes, paths: info.encryptedFieldPaths) {
            return refused(refusal)
        }
        let validator = MongoValidatorRewrite.rewrite(info.validatorJson, applying: changes)
        if let refusal = validator.refusal
            ?? MongoFieldDependent.view(of: changes, among: views, collection: info.name)?.refusal(collection: info.name) {
            return refused(refusal)
        }
        return MongoFieldChangeAssessment(
            refusal: nil,
            rewrittenValidatorJson: validator.rewrittenJson,
            effectiveValidatorJson: validator.rewrittenJson ?? info.validatorJson
        )
    }

    /// The statement that puts the rewritten validator in place, ahead of the updates. Level and
    /// action are left out, so the collection keeps its own. `mongoc_client_command_simple` sends
    /// no write concern of its own, so the connection's goes in the command.
    static func validatorStatement(
        collection: String,
        validatorJson: String,
        writeConcern: MongoWriteConcern
    ) -> String {
        var members = [
            "\"collMod\": \(MongoScriptJson.jsonString(collection))",
            "\"validator\": \(validatorJson)"
        ]
        if let concern = writeConcern.schemaChangeJson {
            members.append("\"writeConcern\": \(concern)")
        }
        return "db.runCommand({\(members.joined(separator: ", "))})"
    }

    /// What runs ahead of the updates: the `collMod` that carries the validator along, when the
    /// edits change it.
    func leadingStatements(collection: String, writeConcern: MongoWriteConcern) -> [String] {
        guard let rewrittenValidatorJson else { return [] }
        return [
            Self.validatorStatement(collection: collection, validatorJson: rewrittenValidatorJson, writeConcern: writeConcern)
        ]
    }

    /// Why the statements the save was composed with must not run, now that the catalog has been
    /// read again: the collection's `listCollections` entry is no longer the one the save was
    /// composed from. The `collMod` holds the whole validator as it was read then, so running it
    /// after someone else changed the validator would put the old one back over theirs, and the
    /// checks after writing read the level, the action and the validator from that entry.
    static func changedSinceComposedRefusal(composedFrom basis: String?, current infoJson: String?, collection: String) -> String? {
        guard basis != infoJson else { return nil }
        return String(
            format: String(localized: "%@ changed after this save was prepared, so nothing was changed. Review the save and save again."),
            collection
        )
    }

    /// Why the save must not write after all, now that the catalog has been read once more, as the
    /// last thing before the first statement. Another client's `collMod` during a scan would
    /// otherwise be overwritten by the one the save composed, and a validation level or action
    /// changed then would leave the scans answering for rules the collection no longer has. Any
    /// change to the collection's `listCollections` entry refuses, and so does any index, search
    /// index or view that now refuses the change.
    static func changedDuringChecksRefusal(
        checked: MongoCatalogRead,
        current: MongoCatalogRead,
        collection: String
    ) -> String? {
        if let refusal = current.assessment.refusal {
            return refusal
        }
        guard current.infoJson == checked.infoJson else {
            return String(
                format: String(localized: "%@ changed while its documents were being checked, so nothing was changed. Save again."),
                collection
            )
        }
        return nil
    }

    private static func refused(_ reason: String) -> MongoFieldChangeAssessment {
        MongoFieldChangeAssessment(refusal: reason, rewrittenValidatorJson: nil, effectiveValidatorJson: nil)
    }

    /// A capped collection holds a fixed number of bytes. Measured on 7.0.43: a rename to a longer
    /// name succeeds and leaves the collection over its size, and the next insert then deletes the
    /// oldest documents until it fits (one insert into a full 4,096-byte collection removed 47 of
    /// 97). A rename that keeps or shortens the name, and a removal, never make a document larger.
    private static func cappedRefusal(_ changes: [MongoFieldChange], info: MongoCollectionInfo) -> String? {
        guard info.isCapped else { return nil }
        for change in changes {
            guard let target = change.target, target.utf8.count > change.source.utf8.count else { continue }
            return String(
                format: String(localized: "%1$@ is a capped collection, and a longer field name makes MongoDB delete its oldest documents. Choose a name no longer than %2$@."),
                info.name, change.source
            )
        }
        return nil
    }

    private static func encryptionRefusal(_ changes: [MongoFieldChange], paths: [String]) -> String? {
        for change in changes {
            for name in change.names where paths.contains(where: { MongoFieldPath.reaches($0, field: name) }) {
                return String(format: String(localized: "%@ is an encrypted field. MongoDB cannot rename or remove it."), name)
            }
        }
        return nil
    }
}

/// Carries a rename or a removal into a `$jsonSchema` validator that declares the field.
///
/// A collection created from New Table declares every field in `$jsonSchema.properties` and lists
/// every field that is not nullable in `required`. Renaming such a field on the documents alone
/// leaves the validator requiring the old name, so every renamed document would fail it, and a
/// field no document holds yet is listed from the validator and could never be removed at all. So
/// the rename or removal is applied to `properties`, `required` and `dependencies` at the schema's
/// top level, where it is a plain change of key. A validator that names the field anywhere else
/// (a query operator, `$expr`, a pattern that matches it, a nested schema) cannot be rewritten
/// faithfully and refuses the save.
enum MongoValidatorRewrite {
    struct Outcome: Equatable {
        let rewrittenJson: String?
        let refusal: String?
    }

    static func rewrite(_ validatorJson: String?, applying changes: [MongoFieldChange]) -> Outcome {
        guard let validatorJson else { return Outcome(rewrittenJson: nil, refusal: nil) }
        var schemaJson = soleJsonSchema(of: validatorJson)
        var changed = false

        if let original = schemaJson {
            var members = MongoScriptJson.members(of: original)
            for change in changes {
                guard let result = apply(change, to: members) else {
                    return Outcome(rewrittenJson: nil, refusal: targetDeclaredRefusal(change))
                }
                changed = changed || result.changed
                members = result.members
            }
            schemaJson = object(members)
        }

        let rewritten = changed ? schemaJson.map { "{\"$jsonSchema\": \($0)}" } : nil
        let effective = rewritten ?? validatorJson
        guard let parsed = MongoJsonValue.parse(effective) else {
            return Outcome(rewrittenJson: nil, refusal: unreadableRefusal)
        }
        for change in changes where MongoQueryFieldReferences.reaches(parsed, field: change.source) {
            return Outcome(rewrittenJson: nil, refusal: namedElsewhereRefusal(change.source))
        }
        if let name = nameRuleConflict(changes, original: MongoJsonValue.parse(validatorJson), rewritten: parsed) {
            return Outcome(rewrittenJson: nil, refusal: namedElsewhereRefusal(name))
        }
        if rewritten != nil, let key = keyTheShellWouldMove(in: parsed) {
            return Outcome(
                rewrittenJson: nil,
                refusal: String(
                    format: String(localized: "The validator has a key named %@ that the shell would reorder or drop. Change the validator from a query tab instead."),
                    key
                )
            )
        }
        return Outcome(rewrittenJson: rewritten, refusal: nil)
    }

    /// A name a `patternProperties` or `additionalProperties` rule applies to: the old name as the
    /// validator stands, where the rule is what checked the field, and the new name as it will
    /// stand, where the rule is what would check it. A name `properties` declares is outside
    /// `additionalProperties`, so a declared field that the rewrite carries along is not caught.
    private static func nameRuleConflict(_ changes: [MongoFieldChange], original: Any?, rewritten: Any) -> String? {
        for change in changes {
            if let original, MongoQueryFieldReferences.appliesByName(original, to: change.source) { return change.source }
            if let target = change.target, MongoQueryFieldReferences.appliesByName(rewritten, to: target) { return target }
        }
        return nil
    }

    private static func soleJsonSchema(of validatorJson: String) -> String? {
        let members = MongoScriptJson.members(of: validatorJson)
        guard members.count == 1, members[0].key == "$jsonSchema" else { return nil }
        return members[0].value
    }

    private typealias Members = [(key: String, value: String)]

    /// Nil when a rename would declare the new name twice.
    private static func apply(_ change: MongoFieldChange, to members: Members) -> (members: Members, changed: Bool)? {
        var changed = false
        var result: Members = []
        for member in members {
            switch member.key {
            case "properties":
                guard let rewritten = renamedKeys(member.value, change: change) else { return nil }
                changed = changed || rewritten.changed
                result.append((member.key, rewritten.json))
            case "required":
                let rewritten = renamedNames(member.value, change: change)
                changed = changed || rewritten.changed
                if let json = rewritten.json { result.append((member.key, json)) }
            case "dependencies":
                guard let rewritten = renamedDependencies(member.value, change: change) else { return nil }
                changed = changed || rewritten.changed
                if let json = rewritten.json { result.append((member.key, json)) }
            default:
                result.append(member)
            }
        }
        return (result, changed)
    }

    private static func renamedKeys(_ objectJson: String, change: MongoFieldChange) -> (json: String, changed: Bool)? {
        let members = MongoScriptJson.members(of: objectJson)
        guard members.contains(where: { $0.key == change.source }) else { return (objectJson, false) }
        if let target = change.target, members.contains(where: { $0.key == target }) { return nil }
        let rewritten: Members = members.compactMap { member in
            guard member.key == change.source else { return member }
            return change.target.map { ($0, member.value) }
        }
        return (object(rewritten), true)
    }

    /// Nil `json` when the list is left empty, which the server refuses: measured on 7.0.43,
    /// `required: []` fails with "$jsonSchema keyword 'required' cannot be an empty array".
    private static func renamedNames(_ arrayJson: String, change: MongoFieldChange) -> (json: String?, changed: Bool) {
        let elements = MongoScriptJson.topLevelElements(arrayJson)
        let names = elements.map { MongoJsonValue.parse($0) as? String }
        guard names.contains(change.source) else { return (arrayJson, false) }
        var rewritten: [String] = []
        for (element, name) in zip(elements, names) {
            guard name == change.source else {
                if !rewritten.contains(element) { rewritten.append(element) }
                continue
            }
            guard let target = change.target else { continue }
            let quoted = MongoScriptJson.jsonString(target)
            if !rewritten.contains(quoted), !names.contains(target) { rewritten.append(quoted) }
        }
        guard !rewritten.isEmpty else { return (nil, true) }
        return ("[\(rewritten.joined(separator: ", "))]", true)
    }

    /// A property dependency (`a: ["b"]`) is a list of names and is rewritten like `required`. A
    /// schema dependency is left alone; the check that follows refuses it when it names the field.
    /// Measured on 7.0.43: a dependency's list cannot be empty either, so an emptied one is dropped.
    private static func renamedDependencies(_ objectJson: String, change: MongoFieldChange) -> (json: String?, changed: Bool)? {
        let members = MongoScriptJson.members(of: objectJson)
        if let target = change.target,
           members.contains(where: { $0.key == change.source }), members.contains(where: { $0.key == target }) {
            return nil
        }
        var changed = false
        var rewritten: Members = []
        for member in members {
            var key = member.key
            if key == change.source {
                changed = true
                guard let target = change.target else { continue }
                key = target
            }
            guard member.value.hasPrefix("[") else {
                rewritten.append((key, member.value))
                continue
            }
            let names = renamedNames(member.value, change: change)
            changed = changed || names.changed
            if let json = names.json { rewritten.append((key, json)) }
        }
        guard changed else { return (objectJson, false) }
        return (rewritten.isEmpty ? nil : object(rewritten), true)
    }

    private static func object(_ members: Members) -> String {
        "{" + members.map { "\(MongoScriptJson.jsonString($0.key)): \($0.value)" }.joined(separator: ", ") + "}"
    }

    /// The `collMod` is a JavaScript object literal, which lists integer-like keys first and reads
    /// `__proto__` as the prototype, so either kind of key would not reach the server as written.
    private static func keyTheShellWouldMove(in value: Any) -> String? {
        if let list = value as? [Any] {
            return list.lazy.compactMap(keyTheShellWouldMove(in:)).first
        }
        guard let object = value as? [String: Any] else { return nil }
        for (key, member) in object {
            if key == "__proto__" || isIntegerLike(key) { return key }
            if let nested = keyTheShellWouldMove(in: member) { return nested }
        }
        return nil
    }

    private static func isIntegerLike(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }) else {
            return false
        }
        return key == "0" || !key.hasPrefix("0")
    }

    private static func targetDeclaredRefusal(_ change: MongoFieldChange) -> String {
        String(
            format: String(localized: "The validator already declares %@. Remove that declaration first, then save again."),
            change.target ?? change.source
        )
    }

    private static func namedElsewhereRefusal(_ field: String) -> String {
        String(
            format: String(localized: "The validator uses %@ in a way that cannot be updated with the field. Change the validator first, then save again."),
            field
        )
    }

    private static var unreadableRefusal: String {
        String(localized: "The validator could not be read, so the change was not checked against it.")
    }
}

/// One read of the catalog for a save, and what it says about the save.
struct MongoCatalogRead {
    /// The collection's `listCollections` entry exactly as the server sent it.
    let infoJson: String?
    let info: MongoCollectionInfo
    let assessment: MongoFieldChangeAssessment
}

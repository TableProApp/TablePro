//
//  MongoFieldReferences.swift
//  MongoDBDriverPlugin
//

import Foundation

/// Whether a server-side definition reads a top-level field, walked from the definition's canonical
/// Extended JSON.
///
/// A validator's query is read by its grammar: it names a field by the key it matches on and never
/// by a value, so `{status: {$in: ["active"]}}` names `status` and not `active`, and an expression
/// names one with a `$`-prefixed string. A view's pipeline and a search index definition are read
/// the other way round, because their grammar keeps growing: `$densify` and `$fill` take a list of
/// plain field names, Atlas Search takes a `path` that can be a list, and a stage added next year
/// can name a field any way it likes. Any string in either that could be the field counts. Where a
/// construct cannot be read statically (`$where`, `$function`, a variable bound to a document, a
/// field name `$getField` computes), every walker answers that it does read the field, because the
/// cost of a wrong yes is a refused save and the cost of a wrong no is a definition left pointing
/// at a field that is gone. An expression handed the whole document, as `$$ROOT` and `$$CURRENT`
/// hand it to `$objectToArray`, can reach any field by a name it builds at run time, so it reads
/// every field too; `MongoWholeDocumentReads` decides that for validators and views alike.
enum MongoFieldPath {
    /// Whether a dotted path is the field or a path under it.
    static func reaches(_ path: String, field: String) -> Bool {
        path == field || path.hasPrefix(field + ".")
    }

    /// Whether a string could name the field: bare or behind `$` or `$$`, and at any depth of a
    /// dotted path, because an earlier stage can put the whole document under another name, as
    /// `$lookup` does with `as` and `$push: "$$ROOT"` does, and `joined.status` then reads `status`.
    static func mayBeNamed(by text: String, field: String) -> Bool {
        text.drop { $0 == "$" }.split(separator: ".", omittingEmptySubsequences: false).contains { $0 == field }
    }
}

enum MongoJsonValue {
    static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// The keys canonical Extended JSON wraps one BSON value in. Such an object is a value, never
    /// a document with fields.
    static let wrapperKeys: Set<String> = [
        "$oid", "$numberInt", "$numberLong", "$numberDouble", "$numberDecimal", "$date",
        "$regularExpression", "$binary", "$timestamp", "$minKey", "$maxKey", "$code", "$symbol",
        "$dbPointer", "$undefined", "$uuid"
    ]

    static func isWrapper(_ object: [String: Any]) -> Bool {
        guard let first = object.keys.first else { return false }
        if object.count == 1 { return wrapperKeys.contains(first) }
        return object.count == 2 && object["$code"] != nil && object["$scope"] != nil
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let object = value as? [String: Any], object.count == 1 else { return nil }
        return object["$literal"] as? String
    }
}

enum MongoExpressionFieldReferences {
    private static let opaqueOperators: Set<String> = ["$function", "$accumulator", "$where"]
    private static let fieldOperators: Set<String> = ["$getField", "$setField", "$unsetField"]

    static func reaches(_ expression: Any, field: String) -> Bool {
        MongoWholeDocumentReads.inExpression(expression) || names(expression, field: field)
    }

    private static func names(_ expression: Any, field: String) -> Bool {
        if let text = expression as? String {
            return stringReaches(text, field: field)
        }
        if let list = expression as? [Any] {
            return list.contains { names($0, field: field) }
        }
        guard let object = expression as? [String: Any], !MongoJsonValue.isWrapper(object) else { return false }
        for (key, value) in object {
            if key == "$literal" { continue }
            if opaqueOperators.contains(key) { return true }
            if fieldOperators.contains(key), fieldOperatorReaches(value, field: field) { return true }
            if names(value, field: field) { return true }
        }
        return false
    }

    /// `"$a.b"` reads `a`. `"$$ROOT.a"` and `"$$CURRENT.a"` read it too, and so may any other
    /// variable followed by a path, because `$let` and `$lookup` can bind a variable to the whole
    /// document. A bare variable names no field: `"$$ROOT"` and `"$$CURRENT"` alone are the whole
    /// document, which `MongoWholeDocumentReads` answers for, and wherever another variable is bound
    /// to the document, the binding names `$$ROOT` itself.
    static func stringReaches(_ text: String, field: String) -> Bool {
        guard text.hasPrefix("$") else { return false }
        guard text.hasPrefix("$$") else {
            return MongoFieldPath.reaches(String(text.dropFirst()), field: field)
        }
        let variablePath = text.dropFirst(2)
        guard let dot = variablePath.firstIndex(of: ".") else { return false }
        return MongoFieldPath.reaches(String(variablePath[variablePath.index(after: dot)...]), field: field)
    }

    /// `$getField: "a"`, and `$getField: {field: "a", input: ...}`, name `a` as a literal. From
    /// MongoDB 7.2 the field argument can be any expression, and one that is not a literal, such as
    /// `{$concat: ["sta", "tus"]}` or `"$name"`, names whatever it evaluates to, so it reaches every
    /// field.
    static func fieldOperatorReaches(_ value: Any, field: String) -> Bool {
        guard let name = literalFieldName(of: value) else { return true }
        return name == field
    }

    /// The field an operator's literal field argument names, or nil when it computes one.
    static func literalFieldName(of value: Any) -> String? {
        literalFieldName(fieldArgument(of: value))
    }

    /// The operator's own value in its short form, and its `field` member in the long one.
    private static func fieldArgument(of value: Any) -> Any? {
        guard let spec = value as? [String: Any], spec["$literal"] == nil else { return value }
        return spec["field"]
    }

    /// A string starting with `$` is a field path or a variable, which evaluates to a name.
    private static func literalFieldName(_ argument: Any?) -> String? {
        if let text = argument as? String { return text.hasPrefix("$") ? nil : text }
        guard let object = argument as? [String: Any], object.count == 1 else { return nil }
        return object["$literal"] as? String
    }
}

/// Whether a validator or a view hands the whole document, `$$ROOT` or `$$CURRENT`, to something
/// that reads its field names, which reads every field. One rule for both, so a validator and a view
/// holding the same expression answer the same.
///
/// `{$objectToArray: "$$ROOT"}` turns every name into a value a literal can match, a comparison of
/// the whole document depends on every name in it, and a document placed under a name, in an array
/// or in a variable can be taken apart by a later stage under that name. The document is only passed
/// on where it stays the document: `$replaceRoot` and `$replaceWith` of it, directly or through
/// `$mergeObjects`, a `$setField` or `$unsetField` with a literal field name, or a branch of `$cond`,
/// `$switch`, `$ifNull` or `$let`. There a later stage can reach it only as `$$ROOT` again, which this
/// rule reads where it stands. A `$getField` with a literal field name reads that one field, which the
/// walkers name as they name any other.
enum MongoWholeDocumentReads {
    private enum Use {
        case readNames
        case passedOn
    }

    private static let wholeDocument: Set<String> = ["$$ROOT", "$$CURRENT"]
    private static let passingOperators: Set<String> = ["$mergeObjects", "$ifNull"]
    private static let documentFieldOperators: Set<String> = ["$setField", "$unsetField"]

    /// A validator's `$expr`, whose value the server reads as a whole.
    static func inExpression(_ expression: Any) -> Bool {
        reads(expression, as: .readNames)
    }

    /// A view's pipeline and every pipeline its stages nest.
    static func inPipeline(_ pipeline: Any) -> Bool {
        guard let stages = pipeline as? [Any] else { return reads(pipeline, as: .readNames) }
        return stages.contains(where: stageReads)
    }

    private static func stageReads(_ stage: Any) -> Bool {
        guard let object = stage as? [String: Any] else { return reads(stage, as: .readNames) }
        return object.contains { name, spec in
            switch name {
            case "$replaceRoot":
                guard let newRoot = (spec as? [String: Any])?["newRoot"] else { return reads(spec, as: .readNames) }
                return reads(newRoot, as: .passedOn)
            case "$replaceWith":
                return reads(spec, as: .passedOn)
            case "$facet":
                guard let facets = spec as? [String: Any] else { return reads(spec, as: .readNames) }
                return facets.values.contains(where: inPipeline)
            case "$lookup", "$unionWith":
                guard let options = spec as? [String: Any] else { return reads(spec, as: .readNames) }
                return options.contains { key, member in
                    key == "pipeline" ? inPipeline(member) : reads(member, as: .readNames)
                }
            default:
                return reads(spec, as: .readNames)
            }
        }
    }

    private static func reads(_ value: Any, as use: Use) -> Bool {
        if let text = value as? String {
            return use == .readNames && wholeDocument.contains(text)
        }
        if let list = value as? [Any] {
            return list.contains { reads($0, as: .readNames) }
        }
        guard let object = value as? [String: Any], !MongoJsonValue.isWrapper(object) else { return false }
        guard object.count == 1, let (key, member) = object.first, key.hasPrefix("$") else {
            return object.values.contains { reads($0, as: .readNames) }
        }
        return operatorReads(key, member, as: use)
    }

    private static func operatorReads(_ name: String, _ member: Any, as use: Use) -> Bool {
        if name == "$literal" { return false }
        if passingOperators.contains(name) {
            return arguments(of: member).contains { reads($0, as: use) }
        }
        if name == "$getField", let spec = member as? [String: Any],
           MongoExpressionFieldReferences.literalFieldName(of: member) != nil {
            return spec["input"].map { reads($0, as: .passedOn) } ?? false
        }
        if documentFieldOperators.contains(name), let spec = member as? [String: Any],
           MongoExpressionFieldReferences.literalFieldName(of: member) != nil {
            return spec.contains { key, argument in reads(argument, as: key == "input" ? use : .readNames) }
        }
        switch name {
        case "$cond":
            return branchesRead(member, conditions: ["if"], results: ["then", "else"], positional: [0], as: use)
        case "$let":
            return branchesRead(member, conditions: ["vars"], results: ["in"], positional: [], as: use)
        case "$switch":
            guard let spec = member as? [String: Any] else { return reads(member, as: .readNames) }
            let branches = (spec["branches"] as? [Any] ?? []).contains { branch in
                branchesRead(branch, conditions: ["case"], results: ["then"], positional: [], as: use)
            }
            return branches || spec["default"].map { reads($0, as: use) } ?? false
        default:
            return reads(member, as: .readNames)
        }
    }

    /// A conditional reads its conditions and passes on whichever result it picks. Written as an
    /// array, `$cond` holds its condition first.
    private static func branchesRead(
        _ member: Any,
        conditions: Set<String>,
        results: Set<String>,
        positional: Set<Int>,
        as use: Use
    ) -> Bool {
        if let list = member as? [Any] {
            return list.enumerated().contains { index, argument in
                reads(argument, as: positional.contains(index) ? .readNames : use)
            }
        }
        guard let spec = member as? [String: Any] else { return reads(member, as: .readNames) }
        return spec.contains { key, argument in
            reads(argument, as: results.contains(key) && !conditions.contains(key) ? use : .readNames)
        }
    }

    private static func arguments(of member: Any) -> [Any] {
        member as? [Any] ?? [member]
    }
}

enum MongoQueryFieldReferences {
    private static let logicalOperators: Set<String> = ["$and", "$or", "$nor"]
    private static let fieldlessOperators: Set<String> = [
        "$comment", "$text", "$alwaysTrue", "$alwaysFalse", "$sampleRate"
    ]

    /// Whether a `$jsonSchema` anywhere in the query applies a rule to this name without declaring
    /// it: a `patternProperties` pattern, or `additionalProperties`. See
    /// `MongoJsonSchemaFieldReferences.appliesByName(_:to:)`.
    static func appliesByName(_ query: Any, to name: String) -> Bool {
        guard let object = query as? [String: Any] else { return false }
        for (key, value) in object {
            if logicalOperators.contains(key), let list = value as? [Any],
               list.contains(where: { appliesByName($0, to: name) }) {
                return true
            }
            if key == "$jsonSchema", MongoJsonSchemaFieldReferences.appliesByName(value, to: name) { return true }
        }
        return false
    }

    /// A query names a field by the key it matches on. What sits under that key is relative to the
    /// field (`$elemMatch` reads the field's own elements), so it is never read for another name.
    static func reaches(_ query: Any, field: String) -> Bool {
        guard let object = query as? [String: Any] else { return false }
        for (key, value) in object {
            if logicalOperators.contains(key) {
                if let list = value as? [Any], list.contains(where: { reaches($0, field: field) }) { return true }
                continue
            }
            switch key {
            case "$expr":
                if MongoExpressionFieldReferences.reaches(value, field: field) { return true }
            case "$jsonSchema":
                if MongoJsonSchemaFieldReferences.reaches(value, field: field) { return true }
            default:
                if fieldlessOperators.contains(key) { continue }
                if key.hasPrefix("$") || MongoFieldPath.reaches(key, field: field) { return true }
            }
        }
        return false
    }
}

enum MongoJsonSchemaFieldReferences {
    private static let combinators = ["allOf", "anyOf", "oneOf"]

    /// A `$jsonSchema` names a document's fields at its own level: `properties`, `required`,
    /// `dependencies`, a `patternProperties` pattern that matches the field, a document listed in
    /// `enum`, and every schema in `allOf`, `anyOf`, `oneOf` and `not`, which apply to the same
    /// document. What a property's own schema says is about that field's value, and `description`,
    /// `title` and a scalar `enum` entry are values.
    static func reaches(_ schema: Any, field: String) -> Bool {
        guard let object = schema as? [String: Any] else { return false }
        if let properties = object["properties"] as? [String: Any], properties[field] != nil { return true }
        if enumListsDocumentsNaming(object, field) { return true }
        if let required = object["required"] as? [Any], required.contains(where: { ($0 as? String) == field }) {
            return true
        }
        if let dependencies = object["dependencies"] as? [String: Any], dependenciesReach(dependencies, field: field) {
            return true
        }
        if let patterns = object["patternProperties"] as? [String: Any],
           patterns.keys.contains(where: { pattern($0, matches: field) }) {
            return true
        }
        for key in combinators {
            if let list = object[key] as? [Any], list.contains(where: { reaches($0, field: field) }) { return true }
        }
        if let negated = object["not"], reaches(negated, field: field) { return true }
        return false
    }

    /// Whether the schema applies a rule to this name by pattern, or through `additionalProperties`
    /// because it neither declares the name nor matches it by pattern, at the document's level or in
    /// a combinator. Such a rule follows the name rather than the field, so a rename moves the field
    /// out from under it or under one it was never checked against, and neither can be carried
    /// along. `additionalProperties: true` and an empty schema check nothing.
    static func appliesByName(_ schema: Any, to name: String) -> Bool {
        guard let object = schema as? [String: Any] else { return false }
        if let patterns = object["patternProperties"] as? [String: Any],
           patterns.keys.contains(where: { pattern($0, matches: name) }) {
            return true
        }
        let declared = (object["properties"] as? [String: Any])?[name] != nil
        if !declared, let additional = object["additionalProperties"], constrains(additional) { return true }
        if enumListsDocumentsNaming(object, name) { return true }
        for key in combinators {
            if let list = object[key] as? [Any], list.contains(where: { appliesByName($0, to: name) }) { return true }
        }
        if let negated = object["not"], appliesByName(negated, to: name) { return true }
        return false
    }

    /// An `enum` at the document's own level lists whole documents, and a document matches one only
    /// while it holds exactly that entry's names, so an entry naming the field ties the rule to the
    /// name. The rewrite cannot carry it along: a `$rename` moves the field to the end of the
    /// document, and a document is equal to an entry only with its fields in the entry's order.
    private static func enumListsDocumentsNaming(_ schema: [String: Any], _ name: String) -> Bool {
        guard let entries = schema["enum"] as? [Any] else { return false }
        return entries.contains { entry in
            guard let document = entry as? [String: Any], !MongoJsonValue.isWrapper(document) else { return false }
            return document[name] != nil
        }
    }

    private static func constrains(_ additionalProperties: Any) -> Bool {
        if let allowed = additionalProperties as? Bool { return !allowed }
        guard let schema = additionalProperties as? [String: Any] else { return true }
        return !schema.isEmpty
    }

    private static func dependenciesReach(_ dependencies: [String: Any], field: String) -> Bool {
        if dependencies[field] != nil { return true }
        return dependencies.values.contains { value in
            if let names = value as? [Any] { return names.contains { ($0 as? String) == field } }
            return reaches(value, field: field)
        }
    }

    /// A pattern that does not compile counts as a match, because nothing can say it does not.
    static func pattern(_ pattern: String, matches field: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return true }
        let range = NSRange(field.startIndex..., in: field)
        return expression.firstMatch(in: field, range: range) != nil
    }
}

enum MongoIndexFieldReferences {
    private static let projectionKeys = ["wildcardProjection", "columnstoreProjection"]

    /// An index reads a field through its key, a text index's `weights` and `language_override`,
    /// its `partialFilterExpression`, and a wildcard or columnstore projection. A text index reports
    /// `language_override: "language"` even when it was never set, and a document that gains a
    /// `language` field with a value the text index does not know stops the write that gave it one.
    static func reaches(_ index: [String: Any], field: String) -> Bool {
        if let key = index["key"] as? [String: Any], key.keys.contains(where: { MongoFieldPath.reaches($0, field: field) }) {
            return true
        }
        if let weights = index["weights"] as? [String: Any],
           weights.keys.contains(where: { MongoFieldPath.reaches($0, field: field) }) {
            return true
        }
        if let override = index["language_override"] as? String, override == field { return true }
        if let filter = index["partialFilterExpression"], MongoQueryFieldReferences.reaches(filter, field: field) {
            return true
        }
        return projectionKeys.contains { key in
            guard let projection = index[key] as? [String: Any] else { return false }
            return projection.keys.contains { MongoFieldPath.reaches($0, field: field) }
        }
    }
}

enum MongoPipelineFieldReferences {
    private static let opaqueOperators: Set<String> = ["$function", "$accumulator", "$where"]
    private static let fieldOperators: Set<String> = ["$getField", "$setField", "$unsetField"]

    /// A view's pipeline reads a field wherever a string in it could name the field, in any stage,
    /// any position and any list, `$literal` included, and wherever a key that is not an operator
    /// does. Output names count too: telling them from inputs means knowing every stage's grammar,
    /// and a stale output name is as wrong as a stale input. The operator-aware rules only add to
    /// that: a code body, and a field name computed at run time. A value BSON keeps as a number, a
    /// date or an id is not a string and names nothing.
    /// Whether a view's pipeline reads the field: by a name that could be the field, or by handing
    /// the whole document to something that reads every name in it.
    static func pipelineReads(_ pipeline: [Any], field: String) -> Bool {
        MongoWholeDocumentReads.inPipeline(pipeline) || reaches(pipeline, field: field)
    }

    static func reaches(_ value: Any, field: String) -> Bool {
        if let text = value as? String {
            return MongoFieldPath.mayBeNamed(by: text, field: field)
        }
        if let list = value as? [Any] {
            return list.contains { reaches($0, field: field) }
        }
        guard let object = value as? [String: Any] else { return false }
        if MongoJsonValue.isWrapper(object) { return wrapperReaches(object, field: field) }
        for (key, member) in object {
            if !key.hasPrefix("$"), MongoFieldPath.mayBeNamed(by: key, field: field) { return true }
            if opaqueOperators.contains(key) { return true }
            if fieldOperators.contains(key), MongoExpressionFieldReferences.fieldOperatorReaches(member, field: field) {
                return true
            }
            if reaches(member, field: field) { return true }
        }
        return false
    }

    /// A symbol is a string under another type, and code can read any field.
    private static func wrapperReaches(_ wrapper: [String: Any], field: String) -> Bool {
        if wrapper["$code"] != nil { return true }
        guard let symbol = wrapper["$symbol"] as? String else { return false }
        return MongoFieldPath.mayBeNamed(by: symbol, field: field)
    }
}

/// Whether an Atlas Search or Vector Search index definition names a field. A definition names one
/// as a key under `mappings.fields`, as a `path` string or list, and in `storedSource`, and every
/// key and every string in it counts, for the same reason a view's do.
enum MongoSearchDefinitionFieldReferences {
    static func reaches(_ value: Any, field: String) -> Bool {
        if let text = value as? String {
            return MongoFieldPath.mayBeNamed(by: text, field: field)
        }
        if let list = value as? [Any] {
            return list.contains { reaches($0, field: field) }
        }
        guard let object = value as? [String: Any], !MongoJsonValue.isWrapper(object) else { return false }
        return object.contains { key, member in
            MongoFieldPath.mayBeNamed(by: key, field: field) || reaches(member, field: field)
        }
    }
}

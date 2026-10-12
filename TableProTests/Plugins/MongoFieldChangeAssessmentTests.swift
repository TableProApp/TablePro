//
//  MongoFieldChangeAssessmentTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// Every `listCollections` and `listIndexes` fixture is the canonical Extended JSON MongoDB 7.0.43
/// returned, byte for byte. `made` is a collection New Table created.
struct MongoFieldChangeAssessmentTests {
    private enum Fixture {
        static let made = #"{ "name" : "made", "type" : "collection", "#
            + #""options" : { "validator" : { "$jsonSchema" : { "bsonType" : "object", "required" : [ "title" ], "#
            + #""properties" : { "_id" : { "bsonType" : "objectId" }, "title" : { "bsonType" : "string" }, "#
            + #""qty" : { "bsonType" : [ "int", "null" ] }, "note" : { "bsonType" : [ "string", "null" ] } } } } }, "#
            + #""info" : { "readOnly" : false, "uuid" : { "$binary" : { "base64" : "uO9RAKO/Q++gkdBY5B0Y3w==", "#
            + #""subType" : "04" } } }, "idIndex" : { "v" : { "$numberInt" : "2" }, "#
            + #""key" : { "_id" : { "$numberInt" : "1" } }, "name" : "_id_" } }"#
        static let plain = #"{ "name" : "fx", "type" : "collection", "options" : {  }, "info" : { "readOnly" : false, "#
            + #""uuid" : { "$binary" : { "base64" : "NmEwJ/xDRUGIfXfL+Gqw/A==", "subType" : "04" } } }, "#
            + #""idIndex" : { "v" : { "$numberInt" : "2" }, "key" : { "_id" : { "$numberInt" : "1" } }, "#
            + #""name" : "_id_" } }"#
        static let moderateWarn = #"{ "name" : "fxv", "type" : "collection", "#
            + #""options" : { "validator" : { "$jsonSchema" : { "bsonType" : "object", "required" : [ "name" ], "#
            + #""properties" : { "name" : { "bsonType" : "string" }, "status" : { "enum" : [ "active", "gone" ] }, "#
            + #""active" : { "bsonType" : "bool" } } } }, "validationLevel" : "moderate", "#
            + #""validationAction" : "warn" }, "info" : { "readOnly" : false, "#
            + #""uuid" : { "$binary" : { "base64" : "k3km2BjsQWqHkYR1Le6t9g==", "subType" : "04" } } }, "#
            + #""idIndex" : { "v" : { "$numberInt" : "2" }, "key" : { "_id" : { "$numberInt" : "1" } }, "#
            + #""name" : "_id_" } }"#
        static let timeseries = #"{ "name" : "fxts", "type" : "timeseries", "options" : { "timeseries" : { "timeField" : "t", "#
            + #""metaField" : "meta", "granularity" : "seconds", "#
            + #""bucketMaxSpanSeconds" : { "$numberInt" : "3600" } } }, "info" : { "readOnly" : false } }"#
        static let view = #"{ "name" : "activeOrders", "type" : "view", "options" : { "viewOn" : "fxo", "#
            + #""pipeline" : [ { "$match" : { "status" : "active" } }, "#
            + #"{ "$project" : { "total" : { "$numberInt" : "1" } } } ] }, "info" : { "readOnly" : true } }"#
        static let byTotal = #"{ "name" : "byTotal", "type" : "view", "options" : { "viewOn" : "activeOrders", "#
            + #""pipeline" : [ { "$sort" : { "total" : { "$numberInt" : "-1" } } } ] }, "#
            + #""info" : { "readOnly" : true } }"#
        static let joined = #"{ "name" : "joined", "type" : "view", "options" : { "viewOn" : "products", "#
            + #""pipeline" : [ { "$lookup" : { "from" : "fxo", "localField" : "sku", "foreignField" : "sku", "#
            + #""as" : "o" } } ] }, "info" : { "readOnly" : true } }"#
        static let emailIndex = #"{ "v" : { "$numberInt" : "2" }, "key" : { "email" : { "$numberInt" : "1" } }, "name" : "email_1", "unique" : true }"#
        static let encrypted = #"{ "name" : "sec", "type" : "collection", "#
            + #""options" : { "encryptedFields" : { "fields" : [ { "path" : "ssn", "bsonType" : "string" } ] } } }"#
        static let capped = #"{ "name" : "fxcap", "type" : "collection", "#
            + #""options" : { "capped" : true, "size" : { "$numberInt" : "4096" } }, "info" : { "readOnly" : false, "#
            + #""uuid" : { "$binary" : { "base64" : "atlITu49RhecdL/EpQ54nw==", "subType" : "04" } } }, "#
            + #""idIndex" : { "v" : { "$numberInt" : "2" }, "key" : { "_id" : { "$numberInt" : "1" } }, "#
            + #""name" : "_id_" } }"#
        static let madeWithExtra = made.replacingOccurrences(
            of: #""note" : "#,
            with: #""extra" : { "bsonType" : "string" }, "note" : "#
        )
    }

    private func info(_ json: String?, _ name: String = "c") -> MongoCollectionInfo {
        MongoCollectionInfo(collection: name, infoJson: json)
    }

    private func assess(
        _ changes: [MongoFieldChange],
        info: MongoCollectionInfo,
        indexes: [String] = [],
        searchIndexes: [String] = [],
        views: [String] = []
    ) -> MongoFieldChangeAssessment {
        MongoFieldChangeAssessment.assess(
            changes,
            info: info,
            indexes: indexes.compactMap(MongoIndexSpec.init(json:)),
            searchIndexes: searchIndexes.compactMap(MongoSearchIndex.init(json:)),
            views: views.compactMap(MongoViewDefinition.init(json:))
        )
    }

    // MARK: - Catalog

    @Test("A collection's kind, validator, level and action are read from listCollections")
    func readsCollectionInfo() {
        let validated = info(Fixture.moderateWarn, "fxv")
        #expect(validated.kind == .collection)
        #expect(validated.validationLevel == "moderate")
        #expect(validated.validationAction == "warn")
        #expect(validated.validatorJson?.hasPrefix(#"{ "$jsonSchema" : { "bsonType" : "object""#) == true)
        #expect(!validated.enforcesValidator)

        let plain = info(Fixture.plain, "fx")
        #expect(plain.validatorJson == nil)
        #expect(plain.validationLevel == "strict")
        #expect(plain.validationAction == "error")

        #expect(info(Fixture.made, "made").enforcesValidator)
        #expect(info(Fixture.timeseries, "fxts").kind == .timeseries)
        #expect(info(Fixture.view, "activeOrders").kind == .view)
        #expect(info(nil, "gone").kind == .missing)
        #expect(info(Fixture.encrypted, "sec").encryptedFieldPaths == ["ssn"])
        #expect(info(Fixture.capped, "fxcap").isCapped)
        #expect(!plain.isCapped)
        #expect(!info(nil, "gone").isCapped)
    }

    @Test("Views that read a collection are found through viewOn chains and joins, in any listing order")
    func viewDependents() throws {
        let views = [Fixture.byTotal, Fixture.view, Fixture.joined].compactMap(MongoViewDefinition.init(json:))
        let dependents = MongoViewDefinition.dependents(of: "fxo", among: views).map(\.name)
        #expect(Set(dependents) == ["activeOrders", "byTotal", "joined"])
        #expect(MongoViewDefinition.dependents(of: "unrelated", among: views).isEmpty)
    }

    @Test("A union and a graph lookup make a view depend on the collection they name")
    func unionAndGraphLookup() throws {
        let union = MongoViewDefinition(name: "u", viewOn: "a", pipeline: [["$unionWith": "c"]])
        let unionSpec = MongoViewDefinition(name: "us", viewOn: "a", pipeline: [["$unionWith": ["coll": "c", "pipeline": []]]])
        let graph = MongoViewDefinition(name: "g", viewOn: "a", pipeline: [["$facet": ["x": [["$graphLookup": ["from": "c"]]]]]])
        let dependents = MongoViewDefinition.dependents(of: "c", among: [union, unionSpec, graph]).map(\.name)
        #expect(Set(dependents) == ["u", "us", "g"])
    }

    // MARK: - Kinds

    @Test("Only a plain collection has fields to rename")
    func kindsAreRefused() {
        let change = [MongoFieldChange.rename(from: "v", to: "w")]
        #expect(assess(change, info: info(Fixture.timeseries, "fxts")).refusal != nil)
        #expect(assess(change, info: info(Fixture.view, "activeOrders")).refusal != nil)
        #expect(assess(change, info: info(nil, "gone")).refusal == String(format: String(localized: "Collection %@ no longer exists."), "gone"))
        #expect(assess(change, info: info(Fixture.plain, "system.buckets.ts")).refusal != nil)
        #expect(assess(change, info: info(Fixture.plain, "fx")).refusal == nil)
    }

    // MARK: - Capped collections

    @Test("A capped collection refuses a rename that makes the name longer in bytes, and nothing else")
    func cappedCollectionsRefuseGrowth() throws {
        let capped = info(Fixture.capped, "fxcap")
        let grown = try #require(assess([.rename(from: "abc", to: "abcd")], info: capped).refusal)
        #expect(grown == String(
            format: String(localized: "%1$@ is a capped collection, and a longer field name makes MongoDB delete its oldest documents. Choose a name no longer than %2$@."),
            "fxcap", "abc"
        ))
        #expect(assess([.rename(from: "ab", to: "\u{1EC5}")], info: capped).refusal != nil)
        #expect(assess([.rename(from: "\u{1EC5}", to: "abc")], info: capped).refusal == nil)
        #expect(assess([.rename(from: "abc", to: "xyz")], info: capped).refusal == nil)
        #expect(assess([.rename(from: "longname", to: "ln")], info: capped).refusal == nil)
        #expect(assess([.remove("abc")], info: capped).refusal == nil)
        #expect(assess([.remove("r"), .rename(from: "a", to: "abc")], info: capped).refusal != nil)
        #expect(assess([.rename(from: "abc", to: "abcd")], info: info(Fixture.plain, "fx")).refusal == nil)
    }

    // MARK: - Indexes and encryption

    @Test("An index refusal names the index, the field and the statement that drops it, for either name")
    func indexRefusal() throws {
        let source = try #require(assess([.rename(from: "email", to: "mail")], info: info(Fixture.plain, "fx"), indexes: [Fixture.emailIndex]).refusal)
        #expect(source.contains("email_1"))
        #expect(source.contains(#"db.fx.dropIndex("email_1")"#))
        let target = try #require(assess([.rename(from: "x", to: "email")], info: info(Fixture.plain, "fx"), indexes: [Fixture.emailIndex]).refusal)
        #expect(target.contains("email_1"))
        #expect(assess([.remove("email")], info: info(Fixture.plain, "fx"), indexes: [Fixture.emailIndex]).refusal != nil)
        #expect(assess([.rename(from: "x", to: "y")], info: info(Fixture.plain, "fx"), indexes: [Fixture.emailIndex]).refusal == nil)
    }

    /// `listIndexes` never lists a search index, so a rename that read it alone left an Atlas Search
    /// or Vector Search definition pointing at a path no document has.
    @Test("A search index that mentions either name refuses the change and is named in the refusal")
    func searchIndexRefusal() throws {
        let searchIndexes = [MongoSearchIndexTests.Fixture.synonymMappings, MongoSearchIndexTests.Fixture.vectorSearch]
        let source = try #require(
            assess([.rename(from: "fullplot", to: "plot")], info: info(Fixture.plain, "movies"), searchIndexes: searchIndexes).refusal
        )
        #expect(source.contains("synonym_mappings"))
        #expect(source.contains("fullplot"))
        let target = try #require(
            assess([.rename(from: "tags", to: "genres")], info: info(Fixture.plain, "movies"), searchIndexes: searchIndexes).refusal
        )
        #expect(target.contains("vector_index"))
        #expect(assess([.remove("plot_embedding")], info: info(Fixture.plain, "movies"), searchIndexes: searchIndexes).refusal != nil)
        #expect(assess([.rename(from: "title", to: "heading")], info: info(Fixture.plain, "movies"), searchIndexes: searchIndexes).refusal == nil)
        #expect(assess([.rename(from: "fullplot", to: "plot")], info: info(Fixture.plain, "movies")).refusal == nil)
    }

    @Test("An encrypted field is refused under either name")
    func encryptedFields() {
        #expect(assess([.rename(from: "ssn", to: "id2")], info: info(Fixture.encrypted, "sec")).refusal != nil)
        #expect(assess([.rename(from: "a", to: "ssn")], info: info(Fixture.encrypted, "sec")).refusal != nil)
        #expect(assess([.remove("a")], info: info(Fixture.encrypted, "sec")).refusal == nil)
    }

    // MARK: - Views

    @Test("A view that reads the old name refuses, and one that reads only the new name does not")
    func viewsReadTheOldNameOnly() throws {
        let views = [Fixture.view, Fixture.byTotal, Fixture.joined]
        let status = try #require(assess([.rename(from: "status", to: "state")], info: info(Fixture.plain, "fxo"), views: views).refusal)
        #expect(status.contains("activeOrders"))
        #expect(assess([.rename(from: "sku", to: "code")], info: info(Fixture.plain, "fxo"), views: views).refusal?.contains("joined") == true)
        #expect(assess([.rename(from: "free", to: "status")], info: info(Fixture.plain, "fxo"), views: views).refusal == nil)
        #expect(assess([.rename(from: "free", to: "gratis")], info: info(Fixture.plain, "fxo"), views: views).refusal == nil)
    }

    // MARK: - Validator rewrite

    @Test("Renaming a field New Table declared renames it in properties and required, in place")
    func renameRewritesNewTableValidator() throws {
        let assessment = assess([.rename(from: "title", to: "name")], info: info(Fixture.made, "made"))
        #expect(assessment.refusal == nil)
        let rewritten = try #require(assessment.rewrittenValidatorJson)
        #expect(rewritten == #"{"$jsonSchema": {"bsonType": "object", "required": ["name"], "#
            + #""properties": {"_id": { "bsonType" : "objectId" }, "name": { "bsonType" : "string" }, "#
            + #""qty": { "bsonType" : [ "int", "null" ] }, "note": { "bsonType" : [ "string", "null" ] }}}}"#)
        #expect(assessment.effectiveValidatorJson == rewritten)
        let schema = MongoDBCollectionSchema.parse(jsonSchema: try #require(MongoScriptJson.member(of: rewritten, key: "$jsonSchema")))
        #expect(schema.fields.map(\.name) == ["_id", "name", "qty", "note"])
        #expect(schema.field(named: "name")?.isRequired == true)
    }

    @Test("Removing a declared field takes it out of properties, and an emptied required list goes too")
    func removalRewritesNewTableValidator() throws {
        let note = try #require(assess([.remove("note")], info: info(Fixture.made, "made")).rewrittenValidatorJson)
        #expect(!note.contains("note"))
        #expect(note.contains(#""required": [ "title" ]"#))
        let title = try #require(assess([.remove("title")], info: info(Fixture.made, "made")).rewrittenValidatorJson)
        #expect(!title.contains("required"))
        #expect(!title.contains("title"))
    }

    @Test("The validator statement is a collMod that leaves level and action alone")
    func validatorStatement() {
        #expect(MongoFieldChangeAssessment.validatorStatement(
            collection: "made", validatorJson: #"{"$jsonSchema": {}}"#, writeConcern: .serverDefault
        ) == #"db.runCommand({"collMod": "made", "validator": {"$jsonSchema": {}}})"#)
    }

    /// `db.runCommand` passes its document on as written, and `mongoc_client_command_simple` adds no
    /// write concern, so a `majority` connection's `collMod` went out with the server's default.
    @Test("The validator statement carries the connection's write concern")
    func validatorStatementCarriesWriteConcern() {
        let majority = MongoWriteConcern(acknowledgement: .majority, journal: nil, timeoutMS: 2_000)
        #expect(MongoFieldChangeAssessment.validatorStatement(
            collection: "made", validatorJson: #"{"$jsonSchema": {}}"#, writeConcern: majority
        ) == #"db.runCommand({"collMod": "made", "validator": {"$jsonSchema": {}}, "writeConcern": {"w": "majority", "wtimeout": 2000}})"#)
        let rename = [MongoFieldChange.rename(from: "title", to: "name")]
        let composed = assess(rename, info: info(Fixture.made, "made")).leadingStatements(collection: "made", writeConcern: majority)
        #expect(composed.count == 1)
        #expect(composed.first?.hasSuffix(#""writeConcern": {"w": "majority", "wtimeout": 2000}})"#) == true)
    }

    /// The composed `collMod` and the checks after writing both come from the entry the save was
    /// composed from, so any change to it since, the validation level included, refuses the save.
    @Test("A save composed from one catalog entry is refused before writing once the entry differs")
    func catalogChangedSinceComposed() {
        let changed = String(
            format: String(localized: "%@ changed after this save was prepared, so nothing was changed. Review the save and save again."),
            "made"
        )
        func refusal(_ current: String?) -> String? {
            MongoFieldChangeAssessment.changedSinceComposedRefusal(composedFrom: Fixture.made, current: current, collection: "made")
        }
        #expect(refusal(Fixture.made) == nil)
        #expect(refusal(Fixture.madeWithExtra) == changed)
        #expect(refusal(Fixture.plain) == changed)
        #expect(refusal(nil) == changed)
        let moderate = Fixture.made.replacingOccurrences(
            of: #""options" : { "validator""#, with: #""options" : { "validationLevel" : "moderate", "validator""#
        )
        #expect(refusal(moderate) == changed)
        #expect(MongoFieldChangeAssessment.changedSinceComposedRefusal(composedFrom: nil, current: Fixture.made, collection: "made") == changed)
    }

    private func catalogRead(
        _ json: String?,
        _ name: String,
        changes: [MongoFieldChange],
        indexes: [String] = []
    ) -> MongoCatalogRead {
        MongoCatalogRead(infoJson: json, info: info(json, name), assessment: assess(changes, info: info(json, name), indexes: indexes))
    }

    /// The scans before writing can each take up to the query timeout, so the catalog is read a
    /// last time once they end, and the save writes only if it still matches what they checked.
    @Test("A catalog that changed while the documents were checked stops the save before its first write")
    func catalogChangedDuringChecks() {
        let rename = [MongoFieldChange.rename(from: "title", to: "name")]
        let checked = catalogRead(Fixture.made, "made", changes: rename)
        func refusal(_ current: MongoCatalogRead) -> String? {
            MongoFieldChangeAssessment.changedDuringChecksRefusal(checked: checked, current: current, collection: "made")
        }

        #expect(refusal(catalogRead(Fixture.made, "made", changes: rename)) == nil)
        #expect(refusal(catalogRead(Fixture.madeWithExtra, "made", changes: rename)) == String(
            format: String(localized: "%@ changed while its documents were being checked, so nothing was changed. Save again."),
            "made"
        ))
        let moderate = Fixture.made.replacingOccurrences(
            of: #""options" : { "validator""#, with: #""options" : { "validationLevel" : "moderate", "validator""#
        )
        #expect(moderate != Fixture.made)
        #expect(refusal(catalogRead(moderate, "made", changes: rename)) == String(
            format: String(localized: "%@ changed while its documents were being checked, so nothing was changed. Save again."),
            "made"
        ))
        let titleIndex = #"{ "v" : { "$numberInt" : "2" }, "key" : { "title" : { "$numberInt" : "1" } }, "name" : "title_1" }"#
        #expect(refusal(catalogRead(Fixture.made, "made", changes: rename, indexes: [titleIndex]))?.contains("title_1") == true)
        #expect(refusal(catalogRead(nil, "made", changes: rename)) == String(format: String(localized: "Collection %@ no longer exists."), "made"))
    }

    /// Measured on 7.0.43 before this check: under `validationAction: "warn"` the rename of `status`
    /// applied and left this validator matching a key no document has.
    @Test("A validator that reads the whole document refuses a change to any field")
    func wholeDocumentValidator() {
        let validator = #"{ "$expr" : { "$in" : [ "status", { "$map" : { "input" : { "$objectToArray" : "$$ROOT" }, "#
            + #""in" : "$$this.k" } } ] } }"#
        let keyed = info(#"{ "name" : "k", "type" : "collection", "options" : { "validator" : "# + validator + " } }", "k")
        #expect(assess([.rename(from: "status", to: "state")], info: keyed).refusal != nil)
        #expect(assess([.rename(from: "qty", to: "quantity")], info: keyed).refusal != nil)
        #expect(assess([.remove("note")], info: keyed).refusal != nil)
    }

    @Test("A name patternProperties or additionalProperties applies to refuses, and a declared name does not")
    func rulesByNameRefuse() throws {
        let closed = info(#"{ "name" : "c", "type" : "collection", "options" : { "validator" : { "$jsonSchema" : { "#
            + #""required" : [ "a" ], "properties" : { "_id" : { "bsonType" : "objectId" }, "a" : { "bsonType" : "int" } }, "#
            + #""additionalProperties" : false } } } }"#, "c")
        let carried = assess([.rename(from: "a", to: "b")], info: closed)
        #expect(carried.refusal == nil)
        #expect(try #require(carried.rewrittenValidatorJson).contains(#""b": { "bsonType" : "int" }"#))
        #expect(assess([.remove("a")], info: closed).refusal == nil)
        #expect(assess([.rename(from: "x", to: "y")], info: closed).refusal != nil)
        #expect(assess([.remove("x")], info: closed).refusal != nil)

        let patterned = info(#"{ "name" : "p", "type" : "collection", "options" : { "validator" : { "$jsonSchema" : { "#
            + #""properties" : { "a" : { "bsonType" : "int" } }, "patternProperties" : { "^tmp_" : { "bsonType" : "string" } } } } } }"#, "p")
        #expect(assess([.rename(from: "a", to: "tmp_a")], info: patterned).refusal != nil)
        #expect(assess([.rename(from: "tmp_a", to: "b")], info: patterned).refusal != nil)
        #expect(assess([.rename(from: "a", to: "b")], info: patterned).refusal == nil)
    }

    @Test("A field the validator does not name needs no collMod")
    func undeclaredFieldKeepsTheValidator() {
        let assessment = assess([.rename(from: "extra", to: "more")], info: info(Fixture.made, "made"))
        #expect(assessment.refusal == nil)
        #expect(assessment.rewrittenValidatorJson == nil)
        #expect(assessment.effectiveValidatorJson == info(Fixture.made, "made").validatorJson)
    }

    @Test("A rename onto a name the validator already declares is refused")
    func targetAlreadyDeclared() {
        #expect(assess([.rename(from: "qty", to: "note")], info: info(Fixture.made, "made")).refusal != nil)
    }

    @Test("Property dependencies are renamed, and an emptied dependency is dropped")
    func dependenciesAreRewritten() throws {
        let validator = #"{ "$jsonSchema" : { "dependencies" : { "card" : [ "billing" ], "billing" : [ "card", "zip" ] } } }"#
        let json = #"{ "name" : "d", "type" : "collection", "options" : { "validator" : "# + validator + " } }"
        let renamed = try #require(assess([.rename(from: "billing", to: "address")], info: info(json, "d")).rewrittenValidatorJson)
        #expect(renamed == #"{"$jsonSchema": {"dependencies": {"card": ["address"], "address": [ "card", "zip" ]}}}"#)
        let removed = try #require(assess([.remove("card")], info: info(json, "d")).rewrittenValidatorJson)
        #expect(removed == #"{"$jsonSchema": {"dependencies": {"billing": ["zip"]}}}"#)
    }

    @Test("A validator that names the field outside what can be rewritten refuses the save")
    func unrewritableValidators() {
        func collection(_ validator: String) -> MongoCollectionInfo {
            info(#"{ "name" : "v", "type" : "collection", "options" : { "validator" : "# + validator + " } }", "v")
        }
        let query = collection(#"{ "status" : { "$in" : [ "active" ] } }"#)
        #expect(assess([.rename(from: "status", to: "state")], info: query).refusal != nil)
        #expect(assess([.rename(from: "active", to: "live")], info: query).refusal == nil)
        let expression = collection(#"{ "$expr" : { "$gt" : [ "$qty", { "$numberInt" : "0" } ] } }"#)
        #expect(assess([.rename(from: "qty", to: "quantity")], info: expression).refusal != nil)
        let pattern = collection(#"{ "$jsonSchema" : { "patternProperties" : { "^tmp_" : { "bsonType" : "int" } } } }"#)
        #expect(assess([.remove("tmp_a")], info: pattern).refusal != nil)
        #expect(assess([.remove("a")], info: pattern).refusal == nil)
        let mixed = collection(#"{ "$jsonSchema" : { "required" : [ "a" ] }, "b" : { "$exists" : true } }"#)
        #expect(assess([.rename(from: "a", to: "c")], info: mixed).refusal != nil)
    }

    @Test("A rewrite that would carry a key the shell reorders or drops is refused")
    func shellUnsafeKeys() {
        let json = #"{ "name" : "k", "type" : "collection", "#
            + #""options" : { "validator" : { "$jsonSchema" : { "required" : [ "a" ], "#
            + #""properties" : { "a" : { "bsonType" : "int" }, "7" : { "bsonType" : "int" } } } } } }"#
        #expect(assess([.rename(from: "a", to: "b")], info: info(json, "k")).refusal != nil)
        #expect(assess([.rename(from: "x", to: "y")], info: info(json, "k")).refusal == nil)
    }

    @Test("A dependent found after the save says the save ran and names what reads the field, without asking to save again")
    func dependentAfterTheSave() throws {
        let index = try #require(MongoIndexSpec(json: Fixture.emailIndex))
        let changes: [MongoFieldChange] = [.rename(from: "email", to: "mail")]
        let found = try #require(MongoFieldDependent.dependent(of: changes, indexes: [index], searchIndexes: [], views: [], collection: "people"))

        #expect(found == .index(name: "email_1", field: "email"))
        #expect(found.refusal(collection: "people").hasSuffix("then save again."))
        let after = found.appearedDuringSave(collection: "people")
        #expect(after.hasPrefix("The save ran, but index email_1 on people was created while it did and uses email."))
        #expect(!after.contains("save again"))
        #expect(MongoFieldDependent.dependent(of: [.rename(from: "name", to: "title")], indexes: [index], searchIndexes: [], views: [], collection: "people") == nil)
    }
}

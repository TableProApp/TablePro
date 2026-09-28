//
//  MongoFieldReferencesTests.swift
//  TableProTests
//

import Foundation
import Testing

/// The index and view fixtures are the canonical Extended JSON `listIndexes` and `listCollections`
/// returned on MongoDB 7.0.43, byte for byte.
struct MongoFieldReferencesTests {
    private enum Fixture {
        static let idIndex = #"{ "v" : { "$numberInt" : "2" }, "key" : { "_id" : { "$numberInt" : "1" } }, "name" : "_id_" }"#
        static let textIndex = #"{ "v" : { "$numberInt" : "2" }, "key" : { "_fts" : "text", "_ftsx" : { "$numberInt" : "1" } }, "#
            + #""name" : "t_text_sub.x_text", "weights" : { "sub.x" : { "$numberInt" : "1" }, "#
            + #""t" : { "$numberInt" : "5" } }, "default_language" : "english", "language_override" : "language", "#
            + #""textIndexVersion" : { "$numberInt" : "3" } }"#
        static let wildcardIndex = #"{"v":{"$numberInt":"2"},"key":{"$**":{"$numberInt":"1"}},"name":"$**_1","wildcardProjection":{"a":{"$numberInt":"1"}}}"#
        static let partialIndex = #"{ "v" : { "$numberInt" : "2" }, "key" : { "b" : { "$numberInt" : "1" } }, "name" : "b_1", "#
            + #""unique" : true, "partialFilterExpression" : { "a" : { "$gt" : { "$numberInt" : "0" } } } }"#
        static let subtreeIndex = #"{ "v" : { "$numberInt" : "2" }, "key" : { "d.$**" : { "$numberInt" : "1" } }, "name" : "d.$**_1" }"#
    }

    private func index(_ json: String) throws -> MongoIndexSpec {
        try #require(MongoIndexSpec(json: json))
    }

    private func query(_ json: String, reaches field: String) throws -> Bool {
        MongoQueryFieldReferences.reaches(try #require(MongoJsonValue.parse(json)), field: field)
    }

    private func pipeline(_ json: String, reaches field: String) throws -> Bool {
        MongoPipelineFieldReferences.reaches(try #require(MongoJsonValue.parse(json)), field: field)
    }

    @Test("A path reaches a field when it is the field or a path under it")
    func pathReach() {
        #expect(MongoFieldPath.reaches("a", field: "a"))
        #expect(MongoFieldPath.reaches("a.b", field: "a"))
        #expect(!MongoFieldPath.reaches("ab", field: "a"))
        #expect(!MongoFieldPath.reaches("b.a", field: "a"))
    }

    @Test("The _id index names _id and nothing else")
    func idIndex() throws {
        let spec = try index(Fixture.idIndex)
        #expect(spec.name == "_id_")
        #expect(spec.reaches("_id"))
        #expect(!spec.reaches("id"))
    }

    @Test("A text index names its weighted fields and its language override, not what sits under them")
    func textIndex() throws {
        let spec = try index(Fixture.textIndex)
        #expect(spec.reaches("t"))
        #expect(spec.reaches("sub"))
        #expect(spec.reaches("language"))
        #expect(!spec.reaches("x"))
        #expect(!spec.reaches("english"))
    }

    @Test("A wildcard index names what its projection names, and a subtree index names its root")
    func wildcardIndexes() throws {
        #expect(try index(Fixture.wildcardIndex).reaches("a"))
        #expect(try index(Fixture.wildcardIndex).reaches("b") == false)
        #expect(try index(Fixture.subtreeIndex).reaches("d"))
        #expect(try index(Fixture.subtreeIndex).reaches("e") == false)
    }

    @Test("A partial index names both its key and the fields of its filter, and b does not name bb")
    func partialIndex() throws {
        let spec = try index(Fixture.partialIndex)
        #expect(spec.reaches("a"))
        #expect(spec.reaches("b"))
        #expect(!spec.reaches("bb"))
    }

    @Test("A query names the keys it matches on and never the values it matches")
    func queryKeysNotValues() throws {
        #expect(try query(#"{"status": {"$in": ["active", "gone"]}}"#, reaches: "status"))
        #expect(try query(#"{"status": {"$in": ["active", "gone"]}}"#, reaches: "active") == false)
        #expect(try query(#"{"$or": [{"a": 1}, {"$and": [{"b.c": 2}]}]}"#, reaches: "b"))
        #expect(try query(#"{"$nor": [{"a": 1}]}"#, reaches: "a"))
        #expect(try query(#"{"items": {"$elemMatch": {"qty": {"$gt": 1}}}}"#, reaches: "qty") == false)
    }

    @Test("$expr names a field by a $-prefixed string or a document variable, never by a literal")
    func expressions() throws {
        #expect(try query(#"{"$expr": {"$gt": ["$qty", {"$numberInt": "0"}]}}"#, reaches: "qty"))
        #expect(try query(#"{"$expr": {"$eq": ["$status", "active"]}}"#, reaches: "active") == false)
        #expect(try query(#"{"$expr": {"$eq": [{"$literal": "$qty"}, "x"]}}"#, reaches: "qty") == false)
        #expect(try query(#"{"$expr": {"$gt": ["$$ROOT.qty", 1]}}"#, reaches: "qty"))
        #expect(try query(#"{"$expr": {"$gt": ["$$CURRENT.qty.n", 1]}}"#, reaches: "qty"))
        #expect(try query(#"{"$expr": {"$gt": [{"$getField": "qty"}, 1]}}"#, reaches: "qty"))
        #expect(try query(#"{"$expr": {"$gt": [{"$getField": {"field": {"$literal": "qty"}, "input": "$$ROOT"}}, 1]}}"#, reaches: "qty"))
        #expect(try query(#"{"$expr": {"$lt": ["$$NOW", "$at"]}}"#, reaches: "qty") == false)
        #expect(try query(#"{"$expr": {"$lt": ["$$NOW", "$at"]}}"#, reaches: "at"))
        #expect(try query(#"{"$expr": {"$function": {"body": "function() {}", "args": [], "lang": "js"}}}"#, reaches: "qty"))
    }

    /// The reviewer's case: every key of the document becomes a value, and a literal matches one.
    /// Nothing in the validator names `status` the way a field is named, and a rename of `status`
    /// would leave it checking a key no document has.
    @Test("An expression handed the whole document reads every field")
    func wholeDocumentReadsEveryField() throws {
        let keys = #"{"$expr": {"$in": ["status", {"$map": {"input": {"$objectToArray": "$$ROOT"}, "in": "$$this.k"}}]}}"#
        #expect(try query(keys, reaches: "status"))
        #expect(try query(keys, reaches: "qty"))
        #expect(try query(#"{"$expr": {"$gt": [{"$size": {"$objectToArray": "$$CURRENT"}}, 3]}}"#, reaches: "qty"))
        #expect(try query(#"{"$expr": {"$eq": ["$$ROOT", "x"]}}"#, reaches: "qty"))
        let merged = #"{"$expr": {"$eq": [{"$mergeObjects": ["$$ROOT", {"a": 1}]}, {"a": 1}]}}"#
        #expect(try query(merged, reaches: "qty"))
        let unset = #"{"$expr": {"$eq": [{"$unsetField": {"field": "a", "input": "$$CURRENT"}}, {}]}}"#
        #expect(try query(unset, reaches: "qty"))
        let set = #"{"$expr": {"$eq": [{"$setField": {"field": "a", "input": "$$ROOT", "value": 1}}, {"a": 1}]}}"#
        #expect(try query(set, reaches: "qty"))
        #expect(try query(#"{"$where": "this.a > 1"}"#, reaches: "qty"))
        let elements = #"{"$expr": {"$anyElementTrue": {"$map": {"input": "$items", "in": {"$eq": ["$$this", 1]}}}}}"#
        #expect(try query(elements, reaches: "items"))
        #expect(try query(elements, reaches: "qty") == false)
    }

    @Test("patternProperties and additionalProperties apply to a name the schema does not declare")
    func rulesByName() throws {
        func applies(_ json: String, to name: String) throws -> Bool {
            MongoQueryFieldReferences.appliesByName(try #require(MongoJsonValue.parse(json)), to: name)
        }
        let closed = #"{"$jsonSchema": {"properties": {"a": {"bsonType": "int"}}, "additionalProperties": false}}"#
        #expect(try applies(closed, to: "a") == false)
        #expect(try applies(closed, to: "b"))
        #expect(try applies(#"{"$jsonSchema": {"additionalProperties": {"bsonType": "string"}}}"#, to: "b"))
        #expect(try applies(#"{"$jsonSchema": {"additionalProperties": true}}"#, to: "b") == false)
        #expect(try applies(#"{"$jsonSchema": {"additionalProperties": {}}}"#, to: "b") == false)
        let patterned = #"{"$jsonSchema": {"patternProperties": {"^tmp_": {"bsonType": "int"}}}}"#
        #expect(try applies(patterned, to: "tmp_x"))
        #expect(try applies(patterned, to: "x") == false)
        #expect(try applies(#"{"$and": [{"$jsonSchema": {"allOf": [{"additionalProperties": false}]}}]}"#, to: "x"))
        #expect(try applies(#"{"$jsonSchema": {"not": {"patternProperties": {"^x$": {}}}}}"#, to: "x"))
        #expect(try applies(#"{"a": {"$exists": true}}"#, to: "a") == false)
    }

    @Test("A field name $getField, $setField or $unsetField computes at run time reaches every field")
    func computedFieldNames() throws {
        let concat = #"{"$getField": {"field": {"$concat": ["sta", "tus"]}, "input": "$$ROOT"}}"#
        #expect(try query(#"{"$expr": {"$eq": ["# + concat + #", 1]}}"#, reaches: "status"))
        #expect(try query(#"{"$expr": {"$eq": ["# + concat + #", 1]}}"#, reaches: "qty"))
        #expect(try pipeline(#"[{"$project": {"s": "# + concat + #"}}]"#, reaches: "status"))
        #expect(try pipeline(#"[{"$project": {"s": {"$getField": "$name"}}}]"#, reaches: "qty"))
        #expect(try pipeline(#"[{"$project": {"s": {"$getField": {"field": "$$key", "input": "$$ROOT"}}}}]"#, reaches: "qty"))
        let unset = #"[{"$replaceWith": {"$unsetField": {"field": {"$toString": "$k"}, "input": "$$ROOT"}}}]"#
        #expect(try pipeline(unset, reaches: "qty"))

        #expect(try pipeline(#"[{"$replaceWith": {"$setField": {"field": "a", "input": "$$ROOT", "value": 1}}}]"#, reaches: "a"))
        #expect(try pipeline(#"[{"$replaceWith": {"$setField": {"field": "a", "input": "$$ROOT", "value": 1}}}]"#, reaches: "b") == false)
        #expect(try query(#"{"$expr": {"$eq": [{"$getField": {"field": {"$literal": "qty"}, "input": "$sub"}}, 1]}}"#, reaches: "note") == false)
        #expect(try query(#"{"$expr": {"$eq": [{"$getField": {"field": {"$literal": "qty"}, "input": "$$ROOT"}}, 1]}}"#, reaches: "note") == false)
        #expect(try query(#"{"$expr": {"$eq": [{"$getField": {"field": {"$literal": "qty"}, "input": "$$ROOT"}}, 1]}}"#, reaches: "qty"))
    }

    private func view(_ json: String, reads field: String) throws -> Bool {
        let stages = try #require(MongoJsonValue.parse(json) as? [Any])
        return MongoViewDefinition(name: "v", viewOn: "c", pipeline: stages).readsField(field)
    }

    /// The reviewer's case in a view: `{$objectToArray: "$$ROOT"}` turns every key into a value, so
    /// a rename changes what the view emits while nothing in it names the field.
    @Test("A view that hands the whole document to something reading its names reads every field")
    func viewReadsEveryFieldThroughTheWholeDocument() throws {
        #expect(try view(#"[{"$project": {"kv": {"$objectToArray": "$$ROOT"}}}]"#, reads: "status"))
        #expect(try view(#"[{"$addFields": {"n": {"$size": {"$objectToArray": "$$CURRENT"}}}}]"#, reads: "qty"))
        #expect(try view(#"[{"$match": {"$expr": {"$eq": ["$$ROOT", {"a": 1}]}}}]"#, reads: "qty"))
        #expect(try view(#"[{"$group": {"_id": null, "docs": {"$push": "$$ROOT"}}}]"#, reads: "qty"))
        #expect(try view(#"[{"$project": {"copy": "$$ROOT"}}]"#, reads: "qty"))
        #expect(try view(#"[{"$lookup": {"from": "o", "let": {"d": "$$ROOT"}, "pipeline": [], "as": "x"}}]"#, reads: "qty"))
        #expect(try view(#"[{"$facet": {"f": [{"$project": {"kv": {"$objectToArray": "$$CURRENT"}}}]}}]"#, reads: "qty"))
        #expect(try view(#"[{"$unionWith": {"coll": "o", "pipeline": [{"$replaceWith": {"$objectToArray": "$$ROOT"}}]}}]"#, reads: "qty"))
        #expect(try view(#"[{"$replaceWith": {"$cond": [{"$eq": ["$$ROOT", {}]}, "$$ROOT", {}]}}]"#, reads: "qty"))
        #expect(try view(#"[{"$replaceWith": {"$mergeObjects": [{"$objectToArray": "$$ROOT"}]}}]"#, reads: "qty"))
    }

    /// A view that passes the document on as the document is the view `[{$match: ...}]` already is:
    /// it reads the fields it names, and a later stage can take the document apart only as `$$ROOT`,
    /// which is read where it stands.
    @Test("A view that keeps the whole document as the document reads only the fields it names")
    func viewPassingTheDocumentOn() throws {
        #expect(try view(#"[{"$replaceRoot": {"newRoot": "$$ROOT"}}]"#, reads: "qty") == false)
        #expect(try view(#"[{"$replaceWith": {"$mergeObjects": [{"note": ""}, "$$ROOT"]}}]"#, reads: "qty") == false)
        #expect(try view(#"[{"$replaceWith": {"$mergeObjects": [{"note": ""}, "$$ROOT"]}}]"#, reads: "note"))
        #expect(try view(#"[{"$replaceWith": {"$setField": {"field": "a", "input": "$$ROOT", "value": 1}}}]"#, reads: "b") == false)
        #expect(try view(#"[{"$replaceWith": {"$unsetField": {"field": "a", "input": "$$CURRENT"}}}]"#, reads: "b") == false)
        let branch = #"[{"$replaceWith": {"$cond": {"if": {"$eq": ["$a", 1]}, "then": "$$ROOT", "else": {"$ifNull": ["$$ROOT", {}]}}}}]"#
        #expect(try view(branch, reads: "qty") == false)
        let switched = #"[{"$replaceWith": {"$switch": {"branches": [{"case": "$flag", "then": "$$ROOT"}], "default": "$$CURRENT"}}}]"#
        #expect(try view(switched, reads: "qty") == false)
        #expect(try view(#"[{"$replaceWith": {"$let": {"vars": {}, "in": "$$ROOT"}}}]"#, reads: "qty") == false)
        #expect(try view(#"[{"$project": {"v": {"$getField": {"field": "a", "input": "$$ROOT"}}}}]"#, reads: "qty") == false)
        #expect(try view(#"[{"$project": {"v": {"$getField": {"field": "a", "input": "$$ROOT"}}}}]"#, reads: "a"))
        #expect(try view(#"[{"$replaceWith": {"$setField": {"field": "a", "input": "$$ROOT", "value": "$$ROOT"}}}]"#, reads: "b"))
    }

    /// One rule, so the same expression reads the same fields whether a validator's `$expr` holds it
    /// or a view computes it.
    @Test("A validator and a view holding the same expression answer the same for a field neither names")
    func validatorAndViewAgree() throws {
        let expressions = [
            #"{"$objectToArray": "$$ROOT"}"#,
            #"{"$size": {"$objectToArray": "$$CURRENT"}}"#,
            #"{"$eq": ["$$ROOT", {"a": 1}]}"#,
            #"{"$mergeObjects": ["$$ROOT", {"a": 1}]}"#,
            #"{"$setField": {"field": "a", "input": "$$ROOT", "value": 1}}"#,
            #"{"$unsetField": {"field": "a", "input": "$$CURRENT"}}"#,
            #"{"$getField": {"field": "a", "input": "$$ROOT"}}"#,
            #"{"$getField": {"field": "a", "input": {"$mergeObjects": ["$$ROOT", {}]}}}"#,
            #"{"$let": {"vars": {"d": "$$ROOT"}, "in": "$$d.a"}}"#,
            #"{"$cond": [true, "$$ROOT", {}]}"#,
            #"{"$gt": ["$a", 1]}"#
        ]
        for text in expressions {
            let expression = try #require(MongoJsonValue.parse(text))
            let validator = MongoQueryFieldReferences.reaches(["$expr": expression], field: "unnamed")
            let pipeline = try #require(MongoJsonValue.parse(#"[{"$project": {"x": "# + text + "}}]") as? [Any])
            let viewReads = MongoViewDefinition(name: "v", viewOn: "c", pipeline: pipeline).readsField("unnamed")
            #expect(validator == viewReads, "\(text)")
        }
        #expect(MongoQueryFieldReferences.reaches(["$expr": ["$getField": ["field": "a", "input": "$$ROOT"]]], field: "unnamed") == false)
        #expect(MongoQueryFieldReferences.reaches(["$expr": ["$objectToArray": "$$ROOT"]], field: "unnamed"))
    }

    /// A document-level `enum` lists whole documents, and a document matches an entry only with
    /// exactly its names. A rename carried only through `properties` left this validator matching
    /// no renamed document.
    @Test("A document listed in a schema's enum names the fields it holds, at the document's level only")
    func documentEnumEntriesNameFields() throws {
        let listed = #"{"$jsonSchema": {"enum": [{"_id": 1, "old": "a"}, {"_id": 2, "old": "b"}]}}"#
        #expect(try query(listed, reaches: "old"))
        #expect(try query(listed, reaches: "new") == false)
        #expect(try query(#"{"$jsonSchema": {"anyOf": [{"enum": [{"old": 1}]}]}}"#, reaches: "old"))
        #expect(try query(#"{"$jsonSchema": {"properties": {"tags": {"enum": [{"old": 1}]}}}}"#, reaches: "old") == false)
        #expect(try query(#"{"$jsonSchema": {"enum": ["old", {"$numberInt": "1"}]}}"#, reaches: "old") == false)
        func applies(_ json: String, to name: String) throws -> Bool {
            MongoQueryFieldReferences.appliesByName(try #require(MongoJsonValue.parse(json)), to: name)
        }
        #expect(try applies(listed, to: "old"))
        #expect(try applies(#"{"$jsonSchema": {"not": {"enum": [{"new": 1}]}}}"#, to: "new"))
        #expect(try applies(listed, to: "other") == false)
    }

    @Test("A variable bound to the document with $let is read as the document")
    func letBoundDocument() throws {
        #expect(try query(#"{"$expr": {"$let": {"vars": {"doc": "$$ROOT"}, "in": {"$gt": ["$$doc.qty", 0]}}}}"#, reaches: "qty"))
    }

    @Test("$jsonSchema names its required, properties and dependencies at the document's level only")
    func jsonSchemaLevels() throws {
        let schema = #"{"$jsonSchema": {"bsonType": "object", "required": ["name"], "#
            + #""properties": {"name": {"bsonType": "string"}, "status": {"enum": ["active", "gone"]}, "#
            + #""active": {"bsonType": "bool"}, "address": {"bsonType": "object", "#
            + #""properties": {"zip": {"bsonType": "string"}}}}, "description": "city"}}"#
        #expect(try query(schema, reaches: "name"))
        #expect(try query(schema, reaches: "status"))
        #expect(try query(schema, reaches: "active"))
        #expect(try query(schema, reaches: "zip") == false)
        #expect(try query(schema, reaches: "gone") == false)
        #expect(try query(schema, reaches: "city") == false)
        #expect(try query(#"{"$jsonSchema": {"dependencies": {"a": ["b"]}}}"#, reaches: "a"))
        #expect(try query(#"{"$jsonSchema": {"dependencies": {"a": ["b"]}}}"#, reaches: "b"))
        #expect(try query(#"{"$jsonSchema": {"allOf": [{"required": ["x"]}]}}"#, reaches: "x"))
        #expect(try query(#"{"$jsonSchema": {"not": {"required": ["x"]}}}"#, reaches: "x"))
    }

    @Test("A pattern names the fields it matches, and a pattern that does not compile names every field")
    func patternProperties() throws {
        let schema = #"{"$jsonSchema": {"patternProperties": {"^tmp_": {"bsonType": "int"}}}}"#
        #expect(try query(schema, reaches: "tmp_x"))
        #expect(try query(schema, reaches: "x") == false)
        #expect(try query(#"{"$jsonSchema": {"patternProperties": {"([": {}}}}"#, reaches: "x"))
    }

    @Test("A view's pipeline names match and projection keys, $-strings and literal field parameters")
    func pipelines() throws {
        let activeOrders = #"[ { "$match" : { "status" : "active" } }, { "$project" : { "total" : { "$numberInt" : "1" } } } ]"#
        #expect(try pipeline(activeOrders, reaches: "status"))
        #expect(try pipeline(activeOrders, reaches: "total"))
        #expect(try pipeline(activeOrders, reaches: "stat") == false)
        let joined = #"[ { "$lookup" : { "from" : "orders", "localField" : "sku", "foreignField" : "code", "as" : "o" } } ]"#
        #expect(try pipeline(joined, reaches: "sku"))
        #expect(try pipeline(joined, reaches: "code"))
        #expect(try pipeline(#"[{"$unset": ["a", "b"]}]"#, reaches: "b"))
        #expect(try pipeline(#"[{"$unset": "a"}]"#, reaches: "a"))
        #expect(try pipeline(#"[{"$group": {"_id": "$$CURRENT.note"}}]"#, reaches: "note"))
        #expect(try pipeline(#"[{"$facet": {"x": [{"$sortByCount": "$tag"}]}}]"#, reaches: "tag"))
        #expect(try pipeline(#"[{"$match": {"at": {"$date": {"$numberLong": "0"}}}}]"#, reaches: "numberLong") == false)
        #expect(try pipeline(#"[{"$addFields": {"k": {"$getField": "tag"}}}]"#, reaches: "tag"))
        #expect(try pipeline(#"[{"$addFields": {"k": {"$function": {"body": "", "args": [], "lang": "js"}}}}]"#, reaches: "x"))
    }

    /// A view's grammar keeps growing, so any string in it that could be the field counts, values
    /// and `$literal` included. A value that only looks like the field is a refused save; a stage
    /// that names the field in a way a list of parameters does not know is a view left reading a
    /// field that is gone.
    @Test("Any string in a view that could be the field counts, values and $literal included")
    func pipelineStringsCountWherever() throws {
        let activeOrders = #"[ { "$match" : { "status" : "active" } } ]"#
        #expect(try pipeline(activeOrders, reaches: "active"))
        #expect(try pipeline(#"[{"$lookup": {"from": "orders", "localField": "a", "foreignField": "b", "as": "o"}}]"#, reaches: "orders"))
        #expect(try pipeline(#"[{"$project": {"k": {"$literal": "$tag"}}}]"#, reaches: "tag"))
        #expect(try pipeline(#"[{"$project": {"p": {"$getField": {"$literal": "$price"}}}}]"#, reaches: "price"))
        #expect(try pipeline(#"[{"$project": {"k": {"$literal": "tag.x"}}}]"#, reaches: "tag"))
    }

    @Test("$densify and $fill name the fields of their partitionByFields list")
    func partitionByFieldsLists() throws {
        let densify = #"[ { "$densify" : { "field" : "ts", "partitionByFields" : [ "tenant" ], "#
            + #""range" : { "step" : { "$numberInt" : "1" }, "unit" : "hour", "bounds" : "partition" } } } ]"#
        #expect(try pipeline(densify, reaches: "tenant"))
        #expect(try pipeline(densify, reaches: "ts"))
        #expect(try pipeline(densify, reaches: "ten") == false)
        let fill = #"[ { "$fill" : { "partitionByFields" : [ "region", "tenant" ], "sortBy" : { "ts" : { "$numberInt" : "1" } }, "#
            + #""output" : { "qty" : { "method" : "linear" } } } } ]"#
        #expect(try pipeline(fill, reaches: "tenant"))
        #expect(try pipeline(fill, reaches: "region"))
        #expect(try pipeline(fill, reaches: "qty"))
        #expect(try pipeline(fill, reaches: "price") == false)
    }

    @Test("A path given as a list names every field in it, and a path under the field names the field")
    func arrayValuedPath() throws {
        let search = #"[{"$search": {"text": {"query": "x", "path": ["title", "tenant.name"]}}}]"#
        #expect(try pipeline(search, reaches: "tenant"))
        #expect(try pipeline(search, reaches: "title"))
        #expect(try pipeline(search, reaches: "x"))
        #expect(try pipeline(search, reaches: "titles") == false)
        #expect(try pipeline(#"[{"$search": {"text": {"query": "x", "path": {"wildcard": "tenant.*"}}}}]"#, reaches: "tenant"))
    }

    @Test("A stage this build has never heard of still names the field wherever a string does")
    func unknownStage() throws {
        #expect(try pipeline(#"[{"$futureStage": {"by": "tenant"}}]"#, reaches: "tenant"))
        #expect(try pipeline(#"[{"$futureStage": ["region", "tenant"]}]"#, reaches: "tenant"))
        #expect(try pipeline(#"[{"$futureStage": {"keys": [{"on": "$tenant.id"}]}}]"#, reaches: "tenant"))
        #expect(try pipeline(#"[{"$futureStage": {"tenant": true}}]"#, reaches: "tenant"))
        #expect(try pipeline(#"[{"$futureStage": {"by": "tenants"}}]"#, reaches: "tenant") == false)
    }

    /// Measured on 7.0.43: this view reads `[{"_id": 1, "s": [{"tenant": "a"}]}]`, and after the
    /// collection's `tenant` was renamed it read `[{"_id": 1, "s": [{}]}]` with no error.
    @Test("A field read under a name an earlier stage gave the document counts")
    func fieldUnderAnotherName() throws {
        let joined = #"[{"$lookup": {"from": "src", "localField": "sid", "foreignField": "sid", "as": "s"}}, "#
            + #"{"$project": {"s.tenant": {"$numberInt": "1"}}}]"#
        #expect(try pipeline(joined, reaches: "tenant"))
        #expect(try pipeline(#"[{"$group": {"_id": null, "docs": {"$push": "$$ROOT"}}}, {"$match": {"docs.tenant": "a"}}]"#, reaches: "tenant"))
        #expect(try pipeline(#"[{"$project": {"t": "$doc.tenant"}}]"#, reaches: "tenant"))
    }

    @Test("A number, a date or an id names no field, a symbol names one like a string, and code reads every field")
    func wrappedValues() throws {
        #expect(try pipeline(#"[{"$limit": {"$numberInt": "5"}}]"#, reaches: "5") == false)
        #expect(try pipeline(#"[{"$match": {"_id": {"$oid": "6ab746850efe77e864860657"}}}]"#, reaches: "6ab746850efe77e864860657") == false)
        #expect(try pipeline(#"[{"$project": {"s": {"$literal": {"$symbol": "tenant"}}}}]"#, reaches: "tenant"))
        #expect(try pipeline(#"[{"$match": {"$where": {"$code": "this.x"}}}]"#, reaches: "tenant"))
        #expect(try pipeline(#"[{"$project": {"c": {"$literal": {"$code": "1"}}}}]"#, reaches: "tenant"))
    }
}

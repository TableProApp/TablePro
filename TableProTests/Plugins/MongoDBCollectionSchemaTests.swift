//
//  MongoDBCollectionSchemaTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MongoDBCollectionSchemaTests {
    /// A `listCollections` reply as `bson_as_canonical_extended_json` writes it, fields deliberately
    /// out of alphabetical order so a dictionary round trip would show.
    private func reply(options: String) -> String {
        """
        { "cursor" : { "id" : { "$numberLong" : "0" }, "ns" : "blog.$cmd.listCollections", "firstBatch" : [ \
        { "name" : "articles", "type" : "collection", "options" : \(options), \
        "info" : { "readOnly" : false }, "idIndex" : { "v" : { "$numberInt" : "2" }, "key" : { "_id" : { "$numberInt" : "1" } }, "name" : "_id_" } } ] }, \
        "ok" : { "$numberDouble" : "1.0" } }
        """
    }

    private let articlesOptions = """
    { "validator" : { "$jsonSchema" : { "bsonType" : "object", "required" : [ "title", "status" ], \
    "properties" : { "title" : { "bsonType" : "string" }, "tags" : { "bsonType" : [ "array", "null" ] }, \
    "date" : { "bsonType" : [ "date", "null" ] }, "status" : { "enum" : [ "draft", "live" ] }, \
    "views" : { "bsonType" : "long" }, "attachment" : { "bsonType" : "binData" }, \
    "score" : { "type" : "number" } } } }, "validationLevel" : "strict", "validationAction" : "error" }
    """

    @Test("Declared fields come back in the order the validator lists them")
    func fieldsKeepTheirOrder() {
        let schema = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: articlesOptions))
        #expect(schema.fields.map { $0.name } == ["title", "tags", "date", "status", "views", "attachment", "score"])
    }

    @Test("A field is required only when the validator's required list names it")
    func requiredComesFromTheRequiredList() throws {
        let schema = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: articlesOptions))
        #expect(try #require(schema.field(named: "title")).isRequired)
        #expect(try #require(schema.field(named: "status")).isRequired)
        #expect(try #require(schema.field(named: "tags")).isRequired == false)
    }

    @Test("A nullable union and a string enum type the value, and an open or binary type does not")
    func valueKinds() {
        let schema = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: articlesOptions))
        #expect(schema.valueKinds["title"] == .string)
        #expect(schema.valueKinds["tags"] == .array)
        #expect(schema.valueKinds["date"] == .date)
        #expect(schema.valueKinds["views"] == .int64)
        #expect(schema.valueKinds["status"] == .string)
        #expect(schema.valueKinds["attachment"] == nil)
        #expect(schema.valueKinds["score"] == nil)
    }

    @Test("A field takes null only when its declared type lists null, whether or not it is required")
    func nullIsDecidedByTheTypeNotTheRequiredList() throws {
        let schema = MongoDBCollectionSchema.parse(jsonSchema: """
        {"bsonType": "object", "required": ["deletedAt", "title"], "properties": {
          "deletedAt": {"bsonType": ["date", "null"]}, "title": {"bsonType": "string"},
          "nick": {"bsonType": "string"}, "note": {"type": ["string", "null"]}, "free": {"description": "any"},
          "level": {"enum": [1, 2]}, "mode": {"enum": ["a", null]}, "code": {"anyOf": [{"bsonType": "string"}]}
        }}
        """)

        #expect(try #require(schema.field(named: "deletedAt")).admitsNull)
        #expect(try #require(schema.field(named: "title")).admitsNull == false)
        #expect(try #require(schema.field(named: "nick")).admitsNull == false)
        #expect(try #require(schema.field(named: "note")).admitsNull)
        #expect(try #require(schema.field(named: "free")).admitsNull)
        #expect(try #require(schema.field(named: "level")).admitsNull == false)
        #expect(try #require(schema.field(named: "mode")).admitsNull)
        #expect(try #require(schema.field(named: "code")).admitsNull == false)
    }

    /// Measured on 7.0.43: `{s: null}` is refused with 121 under `bsonType: ["string", "null"]` plus
    /// `enum: ["draft"]` and plus `not: {bsonType: "null"}`, and stored under `enum: ["draft", null]`
    /// and under `minLength: 3` with `pattern: "^x"`.
    @Test("Every keyword of a field's rule decides null together, not the type alone")
    func siblingKeywordsDecideNullTogether() throws {
        let schema = MongoDBCollectionSchema.parse(jsonSchema: """
        {"properties": {
          "status": {"bsonType": ["string", "null"], "enum": ["draft"]},
          "stage": {"bsonType": ["string", "null"], "enum": ["draft", null]},
          "code": {"bsonType": ["string", "null"], "minLength": 3, "pattern": "^x"},
          "mode": {"enum": ["a", null], "not": {"bsonType": "null"}},
          "kind": {"type": ["string", "null"], "enum": ["a"]}
        }}
        """)

        #expect(try #require(schema.field(named: "status")).admitsNull == false)
        #expect(try #require(schema.field(named: "stage")).admitsNull)
        #expect(try #require(schema.field(named: "code")).admitsNull)
        #expect(try #require(schema.field(named: "mode")).admitsNull == false)
        #expect(try #require(schema.field(named: "kind")).admitsNull == false)
    }

    /// Measured on 7.0.43: a top-level `anyOf` or `patternProperties` refuses null in a field whose
    /// own rule takes it, and an `additionalProperties` schema refuses it in every undeclared field.
    @Test("A rule over the whole document can refuse null in any field, so none is taken to admit it")
    func documentWideRulesDecideNullForEveryField() {
        for rule in [#""anyOf": [{"properties": {"s": {"bsonType": "string"}}}]"#,
                     #""patternProperties": {"^s": {"bsonType": "string"}}"#,
                     #""dependencies": {"a": {"properties": {"s": {"bsonType": "string"}}}}"#] {
            let schema = MongoDBCollectionSchema.parse(jsonSchema: #"{"properties": {"s": {"bsonType": ["string", "null"]}}, "# + rule + "}")
            #expect(schema.admitsNull(fieldNamed: "s") == false, "\(rule)")
            #expect(schema.admitsNull(fieldNamed: "other") == false, "\(rule)")
        }

        let plain = MongoDBCollectionSchema.parse(jsonSchema: #"{"properties": {"s": {"bsonType": ["string", "null"]}, "t": {"bsonType": "string"}}}"#)
        #expect(plain.admitsNull(fieldNamed: "s"))
        #expect(plain.admitsNull(fieldNamed: "t") == false)
        #expect(plain.admitsNull(fieldNamed: "other"))
    }

    @Test("additionalProperties decides null for the fields the validator does not declare")
    func additionalPropertiesDecidesUndeclaredFields() {
        let typed = MongoDBCollectionSchema.parse(jsonSchema: """
        {"additionalProperties": {"bsonType": "string"}, "properties": {"_id": {}, "t": {"bsonType": ["string", "null"]}}}
        """)
        #expect(typed.admitsNull(fieldNamed: "t"))
        #expect(typed.admitsNull(fieldNamed: "u") == false)

        let nullable = MongoDBCollectionSchema.parse(jsonSchema: #"{"additionalProperties": {"bsonType": ["string", "null"]}}"#)
        #expect(nullable.admitsNull(fieldNamed: "u"))

        let closed = MongoDBCollectionSchema.parse(jsonSchema: #"{"additionalProperties": false, "properties": {"_id": {}}}"#)
        #expect(closed.admitsNull(fieldNamed: "u") == false)
    }

    /// Measured on 7.0.43: `{$jsonSchema: {…s: ["string", "null"]…}, s: {$type: "string"}}` refuses
    /// `{s: null}` with 121, and `validationAction: "warn"` stores it.
    @Test("A query operator beside $jsonSchema refuses null everywhere, and a validator that only warns refuses nothing")
    func validatorSettingsDecideNull() {
        let besideSchema = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: """
        { "validator" : { "$jsonSchema" : { "properties" : { "s" : { "bsonType" : [ "string", "null" ] } } },         "s" : { "$type" : "string" } } }
        """))
        #expect(besideSchema.field(named: "s") != nil)
        #expect(besideSchema.admitsNull(fieldNamed: "s") == false)

        let queryOnly = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: """
        { "validator" : { "age" : { "$gte" : { "$numberInt" : "0" } } } }
        """))
        #expect(queryOnly.isEmpty)
        #expect(queryOnly.admitsNull(fieldNamed: "age") == false)

        for setting in [#""validationAction" : "warn""#, #""validationLevel" : "off""#] {
            let unenforced = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: """
            { "validator" : { "$jsonSchema" : { "properties" : { "t" : { "bsonType" : "string" } } } }, \(setting) }
            """))
            #expect(unenforced.admitsNull(fieldNamed: "t"), "\(setting)")
        }

        let enforced = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: articlesOptions))
        #expect(enforced.admitsNull(fieldNamed: "title") == false)
        #expect(enforced.admitsNull(fieldNamed: "date"))
        #expect(MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: "{ }")).admitsNull(fieldNamed: "any"))
    }

    @Test("A string enum is kept as the field's allowed values")
    func enumsAreKept() {
        let schema = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: articlesOptions))
        #expect(schema.allowedValues["status"] == ["draft", "live"])
        #expect(schema.allowedValues["title"] == nil)
    }

    @Test("A declared field is shown with the type name a sampled one of its kind would have")
    func declaredTypeNamesMatchSampledOnes() throws {
        let schema = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: articlesOptions))
        let date = try #require(schema.field(named: "date"))
        let attachment = try #require(schema.field(named: "attachment"))
        let score = try #require(schema.field(named: "score"))
        #expect(date.columnTypeName(representation: .unspecified)
            == BsonDocumentFlattener.typeName(for: .date, representation: .unspecified))
        #expect(attachment.columnTypeName(representation: .unspecified)
            == BsonDocumentFlattener.typeName(for: .binary(subtype: 0), representation: .unspecified))
        #expect(score.columnTypeName(representation: .unspecified) == "number")
    }

    @Test("A collection with no validator, or a validator without $jsonSchema, declares nothing")
    func noSchemaDeclaresNothing() {
        #expect(MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: "{ }")).isEmpty)
        #expect(MongoDBCollectionSchema.parse(
            listCollectionsReply: reply(options: "{ \"validator\" : { \"age\" : { \"$gte\" : { \"$numberInt\" : \"0\" } } } }")
        ).isEmpty)
        #expect(MongoDBCollectionSchema.parse(listCollectionsReply: "{ \"cursor\" : { \"firstBatch\" : [ ] } }").isEmpty)
        #expect(MongoDBCollectionSchema.parse(listCollectionsReply: "not json").isEmpty)
    }

    @Test("A field whose name carries an escaped quote keeps its own name and its place")
    func escapedFieldNamesSurvive() {
        let schema = MongoDBCollectionSchema.parse(jsonSchema: """
        { "properties" : { "a\\"b" : { "bsonType" : "string" }, "ab" : { "bsonType" : "int" }, \
        "plain" : { "bsonType" : "bool" } } }
        """)
        #expect(schema.fields.map { $0.name } == ["a\"b", "ab", "plain"])
    }

    @Test("An enum of strings with no type of its own types the field as a string")
    func stringEnumTypesTheField() throws {
        let schema = MongoDBCollectionSchema.parse(jsonSchema: """
        { "properties" : { "level" : { "enum" : [ "1", "2" ] } } }
        """)
        let level = try #require(schema.field(named: "level"))
        #expect(level.valueKind == .string)
        #expect(level.allowedValues == ["1", "2"])
    }

    /// U+0600 joins the `\` after it into one `Character`, so a scan by `Character` missed the
    /// escape and ended the string at the quote libbson had escaped.
    @Test("A key holding a Prepend character before an escaped quote is read whole")
    func membersReadKeysScalarByScalar() {
        let json = "{\"x\u{0600}\\\"y\": 1, \"next\": 2}"
        let keys = MongoScriptJson.members(of: json).map { $0.key }
        #expect(keys == ["x\u{0600}\"y", "next"])
    }

    @Test("The command asks for one collection by name, escaped")
    func listCollectionsCommandIsEscaped() throws {
        let command = MongoDBCollectionSchema.listCollectionsCommand(for: "a\"b")
        let data = try #require(command.data(using: .utf8))
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((parsed["filter"] as? [String: Any])?["name"] as? String == "a\"b")
        #expect(parsed["maxTimeMS"] as? Int == MongoDBCollectionSchema.listCollectionsTimeoutMS)
    }

    // MARK: - Shape

    @Test("An empty collection presents _id and then its declared fields")
    func emptyCollectionColumns() {
        let schema = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: articlesOptions))
        #expect(MongoDBCollectionShape.emptyCollectionColumns(declaring: schema)
            == ["_id", "title", "tags", "date", "status", "views", "attachment", "score"])
        #expect(MongoDBCollectionShape.emptyCollectionColumns(declaring: .empty) == ["_id"])
    }

    @Test("Declared fields no sampled document holds follow the sampled columns")
    func unseenDeclaredColumns() {
        let schema = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: articlesOptions))
        #expect(MongoDBCollectionShape.declaredColumnsMissing(from: ["_id", "title", "extra"], schema: schema)
            == ["tags", "date", "status", "views", "attachment", "score"])
    }
}

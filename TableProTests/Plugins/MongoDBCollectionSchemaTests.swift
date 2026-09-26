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

    @Test("A nullable union still types the value, and an open or binary type does not")
    func valueKinds() {
        let schema = MongoDBCollectionSchema.parse(listCollectionsReply: reply(options: articlesOptions))
        #expect(schema.valueKinds["title"] == .string)
        #expect(schema.valueKinds["tags"] == .array)
        #expect(schema.valueKinds["date"] == .date)
        #expect(schema.valueKinds["views"] == .int64)
        #expect(schema.valueKinds["status"] == nil)
        #expect(schema.valueKinds["attachment"] == nil)
        #expect(schema.valueKinds["score"] == nil)
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

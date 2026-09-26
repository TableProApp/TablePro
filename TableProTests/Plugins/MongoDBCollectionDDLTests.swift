//
//  MongoDBCollectionDDLTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MongoDBCollectionDDLTests {
    private func column(
        _ name: String,
        _ type: String,
        nullable: Bool = true,
        primaryKey: Bool = false
    ) -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: name,
            dataType: type,
            isNullable: nullable,
            defaultValue: nil,
            isPrimaryKey: primaryKey,
            autoIncrement: false,
            comment: nil,
            unsigned: false,
            onUpdate: nil,
            charset: nil,
            collation: nil
        )
    }

    private func definition(_ name: String, _ columns: [PluginColumnDefinition]) -> PluginCreateTableDefinition {
        PluginCreateTableDefinition(tableName: name, columns: columns)
    }

    private func index(
        _ name: String,
        _ columns: [String],
        unique: Bool = false,
        type: String? = nil,
        whereClause: String? = nil
    ) -> PluginIndexDefinition {
        PluginIndexDefinition(name: name, columns: columns, isUnique: unique, indexType: type, whereClause: whereClause)
    }

    /// The options the statement passes to `createCollection`, read back as JSON.
    private func options(of statement: String) throws -> [String: Any] {
        let start = try #require(statement.firstIndex(of: "{"))
        let end = try #require(statement.lastIndex(of: "}"))
        let data = try #require(String(statement[start ... end]).data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonSchema(of statement: String) throws -> [String: Any] {
        let validator = try #require(try options(of: statement)["validator"] as? [String: Any])
        return try #require(validator["$jsonSchema"] as? [String: Any])
    }

    @Test("The reported draft becomes a collection whose validator lists every field in order")
    func reportedDraftBecomesAValidator() throws {
        let statement = MongoDBCollectionDDL.createCollectionStatement(for: definition("articles", [
            column("_id", "objectId", nullable: false, primaryKey: true),
            column("title", "string", nullable: false),
            column("seoDescription", "string"),
            column("slug", "string"),
            column("content", "string"),
            column("tags", "array"),
            column("lang", "string"),
            column("date", "date"),
            column("schemaVersion", "int")
        ]))

        #expect(statement.hasPrefix("db.createCollection(\"articles\", {"))
        let schema = try jsonSchema(of: statement)
        #expect(schema["bsonType"] as? String == "object")
        #expect(schema["required"] as? [String] == ["title"])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect((properties["_id"] as? [String: Any])?["bsonType"] as? String == "objectId")
        #expect((properties["title"] as? [String: Any])?["bsonType"] as? String == "string")
        #expect((properties["tags"] as? [String: Any])?["bsonType"] as? [String] == ["array", "null"])
        #expect((properties["schemaVersion"] as? [String: Any])?["bsonType"] as? [String] == ["int", "null"])

        let declared = MongoDBCollectionSchema.parse(jsonSchema: statement.jsonSchemaText)
        #expect(declared.fields.map { $0.name } == [
            "_id", "title", "seoDescription", "slug", "content", "tags", "lang", "date", "schemaVersion"
        ])
    }

    @Test("Leaving the server's validation level and action out keeps its strict, error defaults")
    func validationDefaultsAreLeftToTheServer() throws {
        let statement = MongoDBCollectionDDL.createCollectionStatement(
            for: definition("articles", [column("title", "string")])
        )
        let options = try options(of: statement)
        #expect(Set(options.keys) == ["validator"])
    }

    @Test("A collection with no fields beyond _id stays schemaless")
    func onlyIdMeansNoValidator() {
        #expect(MongoDBCollectionDDL.createCollectionStatement(for: definition("events", [])) == "db.createCollection(\"events\")")
        #expect(
            MongoDBCollectionDDL.createCollectionStatement(
                for: definition("events", [column("_id", "objectId", nullable: false, primaryKey: true)])
            ) == "db.createCollection(\"events\")"
        )
    }

    @Test("No required list is written when every field is nullable, because an empty one is refused")
    func noRequiredWhenEverythingIsNullable() throws {
        let statement = MongoDBCollectionDDL.createCollectionStatement(
            for: definition("notes", [column("body", "string")])
        )
        #expect(try jsonSchema(of: statement)["required"] == nil)
    }

    @Test("A type is matched to its alias whatever its case, since the server's aliases are case-sensitive")
    func typeAliasesAreNormalised() throws {
        let statement = MongoDBCollectionDDL.createCollectionStatement(for: definition("t", [
            column("ref", "ObjectId", nullable: false),
            column("name", "STRING", nullable: false),
            column("flag", "Bool", nullable: false)
        ]))
        let properties = try #require(try jsonSchema(of: statement)["properties"] as? [String: Any])
        #expect((properties["ref"] as? [String: Any])?["bsonType"] as? String == "objectId")
        #expect((properties["name"] as? [String: Any])?["bsonType"] as? String == "string")
        #expect((properties["flag"] as? [String: Any])?["bsonType"] as? String == "bool")
    }

    @Test("A nullable null field is not written as a duplicate type")
    func nullTypeIsNotDuplicated() throws {
        let statement = MongoDBCollectionDDL.createCollectionStatement(
            for: definition("t", [column("nothing", "null")])
        )
        let properties = try #require(try jsonSchema(of: statement)["properties"] as? [String: Any])
        #expect((properties["nothing"] as? [String: Any])?["bsonType"] as? String == "null")
    }

    @Test("Names with quotes, backslashes and non-ASCII text stay inside their string literals")
    func namesAreEscaped() throws {
        let statement = MongoDBCollectionDDL.createCollectionStatement(for: definition("a\"b\\c", [
            column("título \"x\"", "string", nullable: false)
        ]))
        #expect(statement.hasPrefix("db.createCollection(\"a\\\"b\\\\c\", {"))
        let schema = try jsonSchema(of: statement)
        #expect(schema["required"] as? [String] == ["título \"x\""])
    }

    @Test("A type MongoDB lacks still produces a statement, so the server explains the refusal")
    func unknownTypeStillProducesAStatement() {
        let statement = MongoDBCollectionDDL.createCollectionStatement(
            for: definition("t", [column("n", "VARCHAR(255)", nullable: false)])
        )
        #expect(statement.contains("\"bsonType\": \"VARCHAR(255)\""))
    }

    // MARK: - Refusals

    @Test("A primary key on a field other than _id is refused and names the field")
    func primaryKeyOnIdFieldIsRefused() throws {
        let reason = try #require(MongoDBCollectionDDL.refusal(for: .addColumn(
            column("id", "objectId", nullable: false, primaryKey: true)
        )))
        #expect(reason.contains("id"))
        #expect(reason.contains("_id"))
    }

    @Test("_id as the primary key is accepted")
    func idAsPrimaryKeyIsAccepted() {
        #expect(MongoDBCollectionDDL.refusal(for: .addColumn(
            column("_id", "objectId", nullable: false, primaryKey: true)
        )) == nil)
    }

    @Test("_id typed as anything but objectId is refused, because the grid lets the server generate it")
    func idWithAnotherTypeIsRefused() {
        #expect(MongoDBCollectionDDL.refusal(for: .addColumn(column("_id", "string", nullable: false))) != nil)
    }

    @Test("A type that is not a BSON alias is refused and names the field and the type")
    func unknownTypeIsRefused() throws {
        let reason = try #require(MongoDBCollectionDDL.refusal(for: .addColumn(column("title", "VARCHAR"))))
        #expect(reason.contains("title"))
        #expect(reason.contains("VARCHAR"))
    }

    @Test("Every listed type is accepted", arguments: MongoDBBsonType.aliases)
    func listedTypesAreAccepted(alias: String) {
        #expect(MongoDBCollectionDDL.refusal(for: .addColumn(column("f", alias))) == nil)
    }

    @Test("Field names a JavaScript object reorders or drops are refused", arguments: ["10", "0", "4294967294", "__proto__"])
    func shellReorderedNamesAreRefused(name: String) {
        #expect(MongoDBCollectionDDL.refusal(for: .addColumn(column(name, "string"))) != nil)
    }

    @Test("Names that only look numeric, or are past the array-index range, are kept", arguments: ["007", "10a", "a10", "4294967295", "99999999999"])
    func nonCanonicalNumericNamesAreKept(name: String) {
        #expect(MongoDBCollectionDDL.refusal(for: .addColumn(column(name, "string"))) == nil)
    }

    @Test("Field names MongoDB cannot address are refused", arguments: ["$price", "a.b"])
    func unaddressableNamesAreRefused(name: String) {
        #expect(MongoDBCollectionDDL.refusal(for: .addColumn(column(name, "string"))) != nil)
    }

    // MARK: - Indexes

    @Test("An index keeps its fields in the order they were given")
    func indexKeepsKeyOrder() {
        let statement = MongoDBCollectionDDL.createIndexStatement(
            collection: "articles", index: index("lang_date", ["lang", "date", "slug"], unique: true)
        )
        #expect(statement == "db.articles.createIndex({\"lang\": 1, \"date\": 1, \"slug\": 1}, {\"name\": \"lang_date\", \"unique\": true})")
    }

    @Test("An index with no name lets the server name it")
    func unnamedIndexOmitsItsName() {
        #expect(MongoDBCollectionDDL.createIndexStatement(collection: "articles", index: index("", ["slug"]))
            == "db.articles.createIndex({\"slug\": 1})")
    }

    @Test("A collection the shell cannot name as a property is reached through getCollection")
    func indexOnAnAwkwardCollectionName() throws {
        let statement = try #require(MongoDBCollectionDDL.createIndexStatement(
            collection: "my.collection", index: index("", ["slug"])
        ))
        #expect(statement.hasPrefix("db.getCollection(\"my.collection\").createIndex("))
    }

    @Test("The editor's index types map to MongoDB's key kinds")
    func indexTypesMap() {
        let cases: [(type: String, key: String)] = [
            ("BTREE", "1"), ("HASH", "\"hashed\""), ("FULLTEXT", "\"text\""), ("SPATIAL", "\"2dsphere\"")
        ]
        for entry in cases {
            let statement = MongoDBCollectionDDL.createIndexStatement(
                collection: "c", index: index("", ["f"], type: entry.type)
            )
            #expect(statement == "db.c.createIndex({\"f\": \(entry.key)})", "\(entry.type)")
        }
    }

    @Test("An index type MongoDB has no equivalent for is refused and produces no statement")
    func unsupportedIndexTypeIsRefused() {
        let gin = index("g", ["f"], type: "GIN")
        #expect(MongoDBCollectionDDL.createIndexStatement(collection: "c", index: gin) == nil)
        #expect(MongoDBCollectionDDL.refusal(for: .addIndex(gin)) != nil)
        #expect(MongoDBCollectionDDL.unsupportedIndexTypes.contains("GIN"))
    }

    @Test("A hashed index can be neither unique nor compound")
    func hashedIndexLimits() {
        #expect(MongoDBCollectionDDL.refusal(for: .addIndex(index("h", ["f"], unique: true, type: "HASH"))) != nil)
        #expect(MongoDBCollectionDDL.refusal(for: .addIndex(index("h", ["f", "g"], type: "HASH"))) != nil)
        #expect(MongoDBCollectionDDL.refusal(for: .addIndex(index("h", ["f"], type: "HASH"))) == nil)
    }

    @Test("An ascending index on _id alone is refused, because MongoDB already has one")
    func indexOnIdIsRefused() {
        #expect(MongoDBCollectionDDL.refusal(for: .addIndex(index("i", ["_id"]))) != nil)
        #expect(MongoDBCollectionDDL.refusal(for: .addIndex(index("i", ["_id", "lang"]))) == nil)
    }

    @Test("A hashed index on _id is its own index, the one a hashed shard key needs")
    func hashedIdIndexIsAccepted() {
        #expect(MongoDBCollectionDDL.refusal(for: .addIndex(index("h", ["_id"], type: "HASH"))) == nil)
    }

    @Test("A text index cannot be unique")
    func uniqueTextIndexIsRefused() {
        #expect(MongoDBCollectionDDL.refusal(for: .addIndex(index("t", ["body"], unique: true, type: "FULLTEXT"))) != nil)
        #expect(MongoDBCollectionDDL.refusal(for: .addIndex(index("t", ["body"], type: "FULLTEXT"))) == nil)
    }

    @Test("A partial index written in SQL is refused")
    func whereClauseIsRefused() {
        #expect(MongoDBCollectionDDL.refusal(for: .addIndex(index("p", ["f"], whereClause: "f > 0"))) != nil)
    }
}

private extension String {
    /// The `$jsonSchema` object inside a `createCollection` statement, as text.
    var jsonSchemaText: String {
        guard let marker = range(of: "\"$jsonSchema\": ") else { return "{}" }
        let tail = self[marker.upperBound...]
        var depth = 0
        var end = tail.startIndex
        for index in tail.indices {
            if tail[index] == "{" { depth += 1 }
            if tail[index] == "}" {
                depth -= 1
                if depth == 0 {
                    end = index
                    break
                }
            }
        }
        return String(tail[tail.startIndex ... end])
    }
}

import Foundation
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

struct MongoDBRowLocatorWriteTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let shown: String
        let locator: String
        let kind: BsonValueKind
        // The kind a cache read in another database, or by shape alone, would type the shown text as.
        let misleadingKind: BsonValueKind

        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(
            name: "UUID",
            shown: #"UUID("0f8fad5b-d9cb-469f-a165-70867728950e")"#,
            locator: #"{"$binary":{"base64":"D4+tW9nLRp+hZXCGdyiVDg==","subType":"04"}}"#,
            kind: .uuid,
            misleadingKind: .string
        ),
        Row(
            name: "24-hex string",
            shown: "507f1f77bcf86cd799439011",
            locator: #""507f1f77bcf86cd799439011""#,
            kind: .string,
            misleadingKind: .objectId
        ),
        Row(
            name: "numeric string",
            shown: "123",
            locator: #""123""#,
            kind: .string,
            misleadingKind: .int64
        ),
        Row(
            name: "ObjectId",
            shown: "507f1f77bcf86cd799439011",
            locator: #"{"$oid":"507f1f77bcf86cd799439011"}"#,
            kind: .objectId,
            misleadingKind: .string
        ),
        Row(
            name: "string that reads as a UUID",
            shown: #"UUID("0f8fad5b-d9cb-469f-a165-70867728950e")"#,
            locator: #""UUID(\"0f8fad5b-d9cb-469f-a165-70867728950e\")""#,
            kind: .string,
            misleadingKind: .uuid
        )
    ]

    // What the kind cache holds at save time: what the read learned, nothing after a reconnect, or after `use otherdb`
    // what a same-named collection there held.
    enum Learned: CaseIterable {
        case loaded, reconnected, moved

        func kinds(_ row: Row) -> Set<BsonValueKind>? {
            switch self {
            case .loaded: return [row.kind]
            case .reconnected: return nil
            case .moved: return [row.misleadingKind]
            }
        }
    }

    private func generator(_ row: Row, kinds: Set<BsonValueKind>?) -> MongoDBStatementGenerator {
        var generator = MongoDBStatementGenerator(
            collectionName: "users", columns: ["_id", "name"], identityKinds: kinds
        )
        generator.rowLocators = [0: row.locator]
        return generator
    }

    private func update(_ row: Row) -> PluginRowChange {
        PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(1, "name", .text("old"), .text("new"))],
            originalRow: [.text(row.shown), .text("old")]
        )
    }

    private func delete(_ row: Row, at index: Int = 0) -> PluginRowChange {
        PluginRowChange(rowIndex: index, type: .delete, cellChanges: [], originalRow: [.text(row.shown), .text("old")])
    }

    @Test("An edit filters on the _id the row was read with, whatever its cell shows and whatever was learned since",
          arguments: rows)
    func editFiltersOnTheLocator(row: Row) throws {
        for learned in Learned.allCases {
            let writes = try generator(row, kinds: learned.kinds(row)).generateRowWrites(
                from: [update(row)], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
            )
            let write = try #require(writes.first, "\(learned)")
            #expect(writes.count == 1)
            #expect(write.statement.hasPrefix(#"db.users.updateOne({"_id":\#(row.locator),"$expr":"#), "\(learned)")
            #expect(write.rowIndices == [0])
        }
    }

    @Test("A delete filters on the _id the row was read with, whatever its cell shows and whatever was learned since",
          arguments: rows)
    func deleteFiltersOnTheLocator(row: Row) throws {
        for learned in Learned.allCases {
            let writes = try generator(row, kinds: learned.kinds(row)).generateRowWrites(
                from: [delete(row)], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
            )
            let statement = try #require(writes.first?.statement)
            #expect(statement.hasPrefix(#"db.users.deleteOne({"_id":\#(row.locator),"$expr":"#), "\(learned)")
            #expect(statement.hasSuffix(#", {"collation":{"locale":"simple"}})"#))
        }
    }

    @Test("Several deletes name every row by its own _id, a string and an ObjectId with the same hex among them")
    func deletesNameEachLocator() throws {
        var generator = MongoDBStatementGenerator(collectionName: "users", columns: ["_id", "name"])
        generator.rowLocators = Dictionary(uniqueKeysWithValues: Self.rows.enumerated().map { ($0.offset, $0.element.locator) })
        let changes = Self.rows.enumerated().map { delete($0.element, at: $0.offset) }

        let writes = try generator.generateRowWrites(
            from: changes, insertedRowData: [:], deletedRowIndices: Set(changes.map(\.rowIndex)), insertedRowIndices: []
        )

        let statement = try #require(writes.first?.statement)
        #expect(statement.hasPrefix(#"db.users.deleteMany({"$or": ["#))
        for row in Self.rows {
            #expect(statement.contains(#"{"_id":\#(row.locator),"$expr":"#))
        }
        #expect(statement.hasSuffix(#", {"collation":{"locale":"simple"}})"#))
        #expect(writes.first?.rowIndices == Array(Self.rows.indices))
    }

    @Test("A row read without a locator is refused, never matched by its shown _id", arguments: rows)
    func rowWithoutLocatorIsRefused(row: Row) {
        let generator = MongoDBStatementGenerator(
            collectionName: "users", columns: ["_id", "name"], identityKinds: [row.kind]
        )
        let refusal = MongoDBWriteRefusal.unlocatedRow.refusal(ofRow: 0)

        #expect(throws: refusal) {
            try generator.generateRowWrites(
                from: [update(row)], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
            )
        }
        #expect(throws: refusal) {
            try generator.generateRowWrites(
                from: [delete(row)], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
            )
        }
    }

    @Test("A locator that is not one plain value, or would match as a pattern, is refused", arguments: [
        #"{"$gt":""}"#,
        #""a"},{"name":"b""#,
        "",
        "not json",
        #"{"$regularExpression":{"pattern":"","options":""}}"#,
        #"[{"$numberInt":"1"}]"#,
        #"{"$numberDouble":"NaN"}"#,
        #"{"$numberDecimal":"NaN"}"#,
        #"{"$code":"return x", "$scope":{"x":{"$numberInt":"1"}}}"#
    ])
    func malformedLocatorIsRefused(locator: String) {
        var generator = MongoDBStatementGenerator(collectionName: "users", columns: ["_id", "name"])
        generator.rowLocators = [0: locator]

        #expect(throws: MongoDBWriteRefusal.unlocatedRow.refusal(ofRow: 0)) {
            try generator.generateRowWrites(
                from: [update(Self.rows[1])], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
            )
        }
    }

    @Test("A typed _id is named in the canonical form it was read in, so it keeps its type")
    func typedLocatorsKeepTheirType() throws {
        let cases: [(locator: String, filtered: String)] = [
            (#"{"$numberInt":"5"}"#, #"{"$numberInt":"5"}"#),
            (#"{"$numberLong":"5"}"#, #"{"$numberLong":"5"}"#),
            (#"{"$numberDouble":"5.0"}"#, #"{"$numberDouble":"5.0"}"#),
            (#"{"$numberDecimal":"5"}"#, #"{"$numberDecimal":"5"}"#),
            (#"{"$date":{"$numberLong":"1704110400500"}}"#, #"{"$date":{"$numberLong":"1704110400500"}}"#),
            (#"{"$timestamp":{"t":5,"i":1}}"#, "Timestamp(5, 1)"),
            (#"{"$minKey":1}"#, "MinKey"),
            ("true", "true"),
            ("null", "null")
        ]
        for (locator, filtered) in cases {
            var generator = MongoDBStatementGenerator(collectionName: "users", columns: ["_id", "name"])
            generator.rowLocators = [0: locator]
            let writes = try generator.generateRowWrites(
                from: [delete(Self.rows[2])], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
            )
            #expect(writes.first?.statement.hasPrefix(#"db.users.deleteOne({"_id":\#(filtered),"$expr":"#) == true)
        }
    }

    @Test("An embedded document _id is named in its stored order, and one the shell would reorder is refused")
    func documentLocatorKeepsItsOrder() throws {
        var generator = MongoDBStatementGenerator(collectionName: "users", columns: ["_id", "name"])
        generator.rowLocators = [0: #"{"b":{"$numberInt":"1"},"a":"x"}"#, 1: #"{"a":"x","2":{"$numberInt":"1"}}"#]

        let kept = try generator.generateRowWrites(
            from: [delete(Self.rows[2])], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )
        #expect(kept.first?.statement.hasPrefix(#"db.users.deleteOne({"_id":{"b":{"$numberInt":"1"},"a":"x"},"$expr":"#) == true)

        #expect(throws: MongoDBWriteRefusal.reorderedByTheShell(field: "_id").refusal(ofRow: 1)) {
            try generator.generateRowWrites(
                from: [delete(Self.rows[2], at: 1)], insertedRowData: [:], deletedRowIndices: [1], insertedRowIndices: []
            )
        }
    }

    @Test("A deleted document is put back with the _id it was read with, after a script's use moved the shell",
          arguments: rows)
    func restoreKeepsTheLocator(row: Row) async throws {
        let mongo = MongoDBPluginDriver(config: DriverConnectionConfig(
            host: "db.example.com", port: 27_017, username: "u", password: "p", database: "app"
        ))
        try await mongo.switchDatabase(to: "other")
        var context = PluginRowWriteContext()
        context.rowLocators = [0: row.locator]
        context.database = "app"

        let restored = mongo.generateIdentityPreservingInsert(
            table: "users", schema: nil, columns: ["_id", "name"], primaryKeyColumns: ["_id"],
            rows: [[.text(row.shown), .text("old")]], absentCells: [:], context: context
        )

        #expect(restored?.map { $0.statement } == [#"db.users.insertOne({"_id": \#(row.locator), "name": "old"})"#])
    }

    @Test("A rewind reads back exactly the documents its locators name")
    func locatorQueryNamesEachDocument() {
        let mongo = MongoDBPluginDriver(config: DriverConnectionConfig(
            host: "db.example.com", port: 27_017, username: "u", password: "p", database: "app"
        ))
        let locators = [Self.rows[1].locator, Self.rows[3].locator]

        let query = mongo.buildLocatorQuery(table: "users", schema: nil, locators: locators, columns: ["_id", "name"])

        #expect(query?.contains(#"{"$or": ["#) == true)
        for locator in locators {
            #expect(query?.contains(#"{"_id":\#(locator),"$expr":"#) == true)
        }
        #expect(query?.contains(#".collation({"locale":"simple"})"#) == true)
        #expect(mongo.buildLocatorQuery(table: "users", schema: nil, locators: [], columns: []) == nil)
        #expect(mongo.buildLocatorQuery(table: "users", schema: nil, locators: [#"{"$gt":""}"#], columns: []) == nil)
    }

    @Test("An edit and delete require the loaded numeric type even when a replacement compares equal")
    func numericReplacementDoesNotMatch() throws {
        let cases = [
            (#"{"$numberInt":"5"}"#, #"["int"]"#),
            (#"{"$numberLong":"5"}"#, #"["long"]"#),
            (#"{"$numberDouble":"5.0"}"#, #"["double"]"#),
            (#"{"$numberDecimal":"5.0"}"#, #"[["decimal","5.0"]]"#),
            (#"{"nested":{"$numberLong":"5"}}"#, #"[["object",["long"]]]"#)
        ]
        for (locator, signature) in cases {
            var generator = generator(Self.rows[2], kinds: nil)
            generator.rowLocators = [0: locator]
            let updated = try generator.generateRowWrites(
                from: [update(Self.rows[2])], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
            )
            let deleted = try generator.generateRowWrites(
                from: [delete(Self.rows[2])], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
            )
            for write in updated + deleted {
                #expect(write.statement.contains(#"{"$eq":[{"_id":"$_id"},{"$literal":{"_id":\#(locator)}}]}"#))
                #expect(write.statement.contains(#"{"$literal":\#(signature)}"#))
                #expect(write.statement.contains(#"{"$type":"$$this"}"#))
                #expect(write.statement.hasSuffix(#", {"collation":{"locale":"simple"}})"#))
            }
        }
    }

    @Test("A collating replacement string cannot receive the loaded row's edit or delete")
    func collatingReplacementDoesNotMatch() throws {
        var generator = generator(Self.rows[2], kinds: nil)
        generator.rowLocators = [0: #""abc""#]
        for deleted in [false, true] {
            let writes = try generator.generateRowWrites(
                from: [deleted ? delete(Self.rows[2]) : update(Self.rows[2])], insertedRowData: [:],
                deletedRowIndices: deleted ? [0] : [], insertedRowIndices: []
            )
            let statement = try #require(writes.first?.statement)
            #expect(statement.contains(#"{"$eq":[{"_id":"$_id"},{"$literal":{"_id":"abc"}}]}"#))
            #expect(statement.contains(#"{"$literal":["string"]}"#))
            #expect(statement.hasSuffix(#", {"collation":{"locale":"simple"}})"#))
        }
    }

    @Test("A limited locator read filters numeric and collating twins before counting rows")
    func locatorReadFiltersBeforeLimit() throws {
        let mongo = MongoDBPluginDriver(config: DriverConnectionConfig(
            host: "db.example.com", port: 27_017, username: "u", password: "p", database: "app"
        ))
        let locators = [#""abc""#, #"{"$numberInt":"5"}"#, #"{"$numberLong":"5"}"#]
        let query = try #require(mongo.buildLocatorQuery(table: "users", schema: nil, locators: locators, columns: []))
        let filter = try #require(query.components(separatedBy: ").limit(").first)
        #expect(filter.contains(#"{"$literal":["string"]}"#))
        #expect(filter.contains(#"{"$literal":["int"]}"#))
        #expect(filter.contains(#"{"$literal":["long"]}"#))
        #expect(query.hasSuffix(#".limit(3).collation({"locale":"simple"})"#))
    }

    @Test("A deleted document read without a locator is not put back under an _id guessed from its text")
    func restoreWithoutLocatorIsRefused() {
        let generator = MongoDBStatementGenerator(
            collectionName: "users", columns: ["_id", "name"], identityKinds: [.string]
        )

        #expect(generator.generateRestore(rows: [[.text("507f1f77bcf86cd799439011"), .text("old")]]) == nil)
    }
}

struct MongoDBBackedDriverLocatorTests {
    // A new driver has learned no _id kinds, which is where a reconnect leaves the session.
    private static func fresh() -> (driver: MongoDBBackedDriver, mongo: MongoDBPluginDriver) {
        let mongo = MongoDBPluginDriver(config: DriverConnectionConfig(
            host: "db.example.com", port: 27_017, username: "u", password: "p", database: "app"
        ))
        return (MongoDBBackedDriver(mongo: mongo, dialedHosts: []), mongo)
    }

    private func update(
        _ driver: MongoDBBackedDriver,
        _ row: MongoDBRowLocatorWriteTests.Row,
        locator: String?
    ) throws -> [PluginRowWrite] {
        try driver.updateWrites(
            table: "users", schema: nil, columns: ["_id", "name"], originalRow: [row.shown, "old"],
            documentLocator: locator, changes: [(column: "name", value: "new")]
        )
    }

    private func delete(
        _ driver: MongoDBBackedDriver,
        _ row: MongoDBRowLocatorWriteTests.Row,
        locator: String?
    ) throws -> [PluginRowWrite] {
        try driver.deleteWrites(
            table: "users", schema: nil, columns: ["_id", "name"], originalRow: [row.shown, "old"],
            documentLocator: locator
        )
    }

    private func expectFiltersOnTheLocator(_ driver: MongoDBBackedDriver, _ row: MongoDBRowLocatorWriteTests.Row) throws {
        let updates = try update(driver, row, locator: row.locator)
        let deletes = try delete(driver, row, locator: row.locator)

        #expect(updates.count == 1)
        #expect(updates.first?.statement.hasPrefix(#"db.users.updateOne({"_id":\#(row.locator),"$expr":"#) == true)
        #expect(deletes.first?.statement.hasPrefix(#"db.users.deleteOne({"_id":\#(row.locator),"$expr":"#) == true)
        #expect(updates.first?.statement.hasSuffix(#", {"collation":{"locale":"simple"}})"#) == true)
        #expect(deletes.first?.statement.hasSuffix(#", {"collation":{"locale":"simple"}})"#) == true)
    }

    @Test("After a reconnect, an edit and a delete filter on the _id the row was read with",
          arguments: MongoDBRowLocatorWriteTests.rows)
    func reconnectedWritesFilterOnTheLocator(row: MongoDBRowLocatorWriteTests.Row) throws {
        try expectFiltersOnTheLocator(Self.fresh().driver, row)
    }

    @Test("After a script's use moved the shell, an edit and a delete still filter on the _id the row was read with",
          arguments: MongoDBRowLocatorWriteTests.rows)
    func movedWritesFilterOnTheLocator(row: MongoDBRowLocatorWriteTests.Row) async throws {
        let (driver, mongo) = Self.fresh()
        try await mongo.switchDatabase(to: "other")

        #expect(mongo.currentDb == "other")
        try expectFiltersOnTheLocator(driver, row)
    }

    @Test("An edit or delete of a row read without a locator is refused, never matched by its shown _id",
          arguments: MongoDBRowLocatorWriteTests.rows)
    func unlocatedWritesAreRefused(row: MongoDBRowLocatorWriteTests.Row) {
        let driver = Self.fresh().driver
        let refusal = MongoDBWriteRefusal.unlocatedRow.refusal(ofRow: 0)

        #expect(throws: refusal) {
            try update(driver, row, locator: nil)
        }
        #expect(throws: refusal) {
            try delete(driver, row, locator: nil)
        }
    }

    @Test("A stored value of a row read without a locator is refused before anything is sent")
    func unlocatedStoredValueIsRefused() async {
        let driver = Self.fresh().driver

        let error = await #expect(throws: DatabaseError.self) {
            try await driver.storedValue(table: "users", schema: nil, column: "name", key: [("_id", "123")], locator: nil)
        }

        #expect(error?.message == MongoDBWriteRefusal.unlocatedRow.reason)
    }
}

//
//  MongoScriptCommandTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoScriptJsonTests {
    @Test("Members come back in the order the document carries them, as text")
    func membersKeepOrder() {
        let members = MongoScriptJson.members(of: "{\"zeta\": 1, \"alpha\": {\"x\": [1, 2]}, \"last\": \"a, b\"}")
        #expect(members.map(\.key) == ["zeta", "alpha", "last"])
        #expect(members.map(\.value) == ["1", "{\"x\": [1, 2]}", "\"a, b\""])
    }

    @Test("A member's value is the text it occupies, not a rebuilt value")
    func memberIsVerbatim() {
        let json = "{\"filter\": {\"b\": 1, \"a\": 2}}"
        #expect(MongoScriptJson.member(of: json, key: "filter") == "{\"b\": 1, \"a\": 2}")
    }

    @Test("A missing member is nil rather than an empty document")
    func missingMember() {
        #expect(MongoScriptJson.member(of: "{\"a\": 1}", key: "b") == nil)
    }

    @Test("Array elements split at the top level only")
    func topLevelElements() {
        let elements = MongoScriptJson.topLevelElements("[{\"a\": [1, 2]}, {\"b\": \"x, y\"}, 3]")
        #expect(elements == ["{\"a\": [1, 2]}", "{\"b\": \"x, y\"}", "3"])
    }

    @Test("An empty array yields no elements")
    func emptyArray() {
        #expect(MongoScriptJson.topLevelElements("[]").isEmpty)
    }

    @Test("Control characters and quotes are escaped")
    func stringEscaping() {
        #expect(MongoScriptJson.jsonString("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\"")
    }

    @Test("A non-finite reply value reads as absent rather than trapping")
    func nonFiniteReplyValues() {
        #expect(MongoScriptJson.number(in: "{\"n\": {\"$numberDouble\": \"NaN\"}}", key: "n") == nil)
        #expect(MongoScriptJson.number(in: "{\"n\": {\"$numberDouble\": \"Infinity\"}}", key: "n") == nil)
        #expect(MongoScriptJson.whole(3.0) == 3)
        #expect(MongoScriptJson.whole(.nan) == nil)
        #expect(MongoScriptJson.whole(.infinity) == nil)
    }

    @Test("A numeric reply field is read through whichever wrapper the server used")
    func numericWrappers() {
        #expect(MongoScriptJson.number(in: "{\"n\": 3}", key: "n") == 3)
        #expect(MongoScriptJson.number(in: "{\"n\": {\"$numberInt\": \"4\"}}", key: "n") == 4)
        #expect(MongoScriptJson.number(in: "{\"n\": {\"$numberLong\": \"5\"}}", key: "n") == 5)
        #expect(MongoScriptJson.number(in: "{\"n\": {\"$numberDouble\": \"6\"}}", key: "n") == 6)
    }
}

struct MongoScriptCursorOptionsTests {
    @Test("A sort written in shell syntax reaches the find options instead of being dropped")
    func sortSurvives() throws {
        var options = MongoScriptCursorOptions.none
        try options.apply(key: "sort", value: "{\"createdAt\":{\"$numberInt\":\"-1\"}}")
        let json = options.findOptionsJson(limit: 100, timeoutMS: 0)
        #expect(json.contains("\"sort\": {\"createdAt\":{\"$numberInt\":\"-1\"}}"))
    }

    @Test("A projection reaches the find options")
    func projectionSurvives() throws {
        var options = MongoScriptCursorOptions.none
        try options.apply(key: "projection", value: "{\"name\":{\"$numberInt\":\"1\"}}")
        #expect(options.findOptionsJson(limit: 10, timeoutMS: 0).contains("\"projection\":"))
    }

    @Test("A whole number arrives wrapped and is read back as a number")
    func wrappedNumbers() throws {
        var options = MongoScriptCursorOptions.none
        try options.apply(key: "limit", value: "{\"$numberInt\":\"25\"}")
        try options.apply(key: "skip", value: "{\"$numberLong\":\"5\"}")
        #expect(options.limit == 25)
        #expect(options.skip == 5)
    }

    @Test("A limit larger than the ceiling is capped, a smaller one is kept")
    func limitRespectsCeiling() {
        var options = MongoScriptCursorOptions.none
        options.limit = 500
        #expect(options.effectiveLimit(ceiling: 201) == 201)
        options.limit = 10
        #expect(options.effectiveLimit(ceiling: 201) == 10)
    }

    @Test("No limit falls back to the ceiling")
    func noLimitUsesCeiling() {
        #expect(MongoScriptCursorOptions.none.effectiveLimit(ceiling: 201) == 201)
    }

    @Test("NaN and infinity are refused rather than crashing the conversion")
    func nonFiniteNumbersAreRefused() {
        var options = MongoScriptCursorOptions.none
        for value in ["{\"$numberDouble\":\"NaN\"}", "{\"$numberDouble\":\"Infinity\"}",
                      "{\"$numberDouble\":\"-Infinity\"}", "{\"$numberDouble\":\"1e30\"}"] {
            #expect(throws: MongoScriptError.self) {
                try options.apply(key: "limit", value: value)
            }
        }
    }

    @Test("An unsupported modifier is refused by name")
    func unsupportedModifier() {
        var options = MongoScriptCursorOptions.none
        #expect(throws: MongoScriptError.self) {
            try options.apply(key: "readConcern", value: "{}")
        }
    }

    @Test("A modifier that wants a number refuses text")
    func nonNumericModifier() {
        var options = MongoScriptCursorOptions.none
        #expect(throws: MongoScriptError.self) {
            try options.apply(key: "limit", value: "\"ten\"")
        }
    }

    @Test("Aggregation takes ordering and paging as appended pipeline stages")
    func aggregateStages() throws {
        var options = MongoScriptCursorOptions.none
        try options.apply(key: "sort", value: "{\"a\":1}")
        try options.apply(key: "limit", value: "5")
        let pipeline = options.decoratedPipeline("[{\"$match\":{}}]")
        #expect(pipeline == "[{\"$match\":{}},{\"$sort\": {\"a\":1}},{\"$limit\": 5}]")
    }

    @Test("An empty pipeline still takes its stages")
    func emptyPipeline() throws {
        var options = MongoScriptCursorOptions.none
        try options.apply(key: "limit", value: "2")
        #expect(options.decoratedPipeline("[]") == "[{\"$limit\": 2}]")
    }

    @Test("The connection's query timeout becomes maxTimeMS when the script names none")
    func timeoutFallback() {
        let json = MongoScriptCursorOptions.none.findOptionsJson(limit: 10, timeoutMS: 3_000)
        #expect(json.contains("\"maxTimeMS\": 3000"))
    }

    @Test("allowDiskUse reaches a find as well as an aggregation")
    func allowDiskUseOnFind() throws {
        var options = MongoScriptCursorOptions.none
        try options.apply(key: "allowDiskUse", value: "true")
        #expect(options.findOptionsJson(limit: 10, timeoutMS: 0).contains("\"allowDiskUse\": true"))
        #expect(options.aggregateOptionsJson(timeoutMS: 0)?.contains("\"allowDiskUse\": true") == true)
    }

    @Test("A maxTimeMS the script set wins over the connection's")
    func explicitTimeoutWins() throws {
        var options = MongoScriptCursorOptions.none
        try options.apply(key: "maxTimeMS", value: "500")
        #expect(options.findOptionsJson(limit: 10, timeoutMS: 3_000).contains("\"maxTimeMS\": 500"))
    }
}

struct MongoScriptCommandBuilderTests {
    @Test("updateMany becomes an update command with multi set")
    func updateMany() {
        let command = MongoScriptCommandBuilder.update(
            collection: "orders", filter: "{\"a\":1}", update: "{\"$set\":{\"b\":2}}",
            multi: true, options: [:], writeConcern: nil
        )
        #expect(command.contains("\"update\": \"orders\""))
        #expect(command.contains("\"q\": {\"a\":1}"))
        #expect(command.contains("\"u\": {\"$set\":{\"b\":2}}"))
        #expect(command.contains("\"multi\": true"))
        #expect(command.contains("\"upsert\": false"))
    }

    @Test("upsert and arrayFilters ride along")
    func updateOptions() {
        let command = MongoScriptCommandBuilder.update(
            collection: "orders", filter: "{}", update: "{}", multi: false,
            options: ["upsert": true, "arrayFilters": [["x.y": 1]]], writeConcern: nil
        )
        #expect(command.contains("\"upsert\": true"))
        #expect(command.contains("\"arrayFilters\":"))
    }

    @Test("deleteOne limits to one document and deleteMany to none")
    func deleteLimits() {
        #expect(
            MongoScriptCommandBuilder
                .delete(collection: "orders", filter: "{}", multi: false, options: [:], writeConcern: nil)
                .contains("\"limit\": 1")
        )
        #expect(
            MongoScriptCommandBuilder
                .delete(collection: "orders", filter: "{}", multi: true, options: [:], writeConcern: nil)
                .contains("\"limit\": 0")
        )
    }

    @Test("findOneAndDelete asks the server to remove rather than update")
    func findAndModifyRemove() {
        let command = MongoScriptCommandBuilder.findAndModify(
            collection: "orders", filter: "{\"a\":1}", update: nil, remove: true, options: [:], writeConcern: nil
        )
        #expect(command.contains("\"remove\": true"))
        #expect(!command.contains("\"update\""))
    }

    @Test("returnDocument after asks for the updated document")
    func findAndModifyReturnsNew() {
        let command = MongoScriptCommandBuilder.findAndModify(
            collection: "orders", filter: "{}", update: "{\"$set\":{}}", remove: false,
            options: ["returnDocument": "after"], writeConcern: nil
        )
        #expect(command.contains("\"new\": true"))
    }

    @Test("An unnamed index takes the name MongoDB gives it")
    func indexNaming() {
        #expect(
            MongoScriptCommandBuilder.indexName(keys: "{\"a\":1,\"b\":-1}", options: [:]) == "a_1_b_-1"
        )
        #expect(
            MongoScriptCommandBuilder.indexName(keys: "{\"loc\":\"2dsphere\"}", options: [:]) == "loc_2dsphere"
        )
        #expect(MongoScriptCommandBuilder.indexName(keys: "{\"a\":1}", options: ["name": "custom"]) == "custom")
    }

    @Test("createIndex passes the options MongoDB accepts")
    func createIndexOptions() {
        let command = MongoScriptCommandBuilder.createIndex(
            collection: "orders", keys: "{\"a\":1}", options: ["unique": true, "expireAfterSeconds": 60]
        )
        #expect(command.contains("\"createIndexes\": \"orders\""))
        #expect(command.contains("\"unique\": true"))
        #expect(command.contains("\"expireAfterSeconds\": 60"))
    }

    @Test("A find for EXPLAIN carries the cursor's own modifiers")
    func explainFind() throws {
        var options = MongoScriptCursorOptions.none
        try options.apply(key: "sort", value: "{\"a\":1}")
        try options.apply(key: "skip", value: "3")
        let command = MongoScriptCommandBuilder.find(
            collection: "orders", filter: "{\"b\":2}", options: options, ceiling: 100
        )
        #expect(command.contains("\"find\": \"orders\""))
        #expect(command.contains("\"filter\": {\"b\":2}"))
        #expect(command.contains("\"sort\": {\"a\":1}"))
        #expect(command.contains("\"skip\": 3"))
    }

    @Test("bulkWrite maps each operation to its own command")
    func bulkOperations() throws {
        let insert = try MongoScriptCommandBuilder.bulkOperation(
            "{\"insertOne\": {\"document\": {\"a\": 1}}}", collection: "orders", writeConcern: nil
        )
        #expect(insert.kind == .insert)
        #expect(insert.document.contains("\"documents\": [{\"a\": 1}]"))

        let update = try MongoScriptCommandBuilder.bulkOperation(
            "{\"updateMany\": {\"filter\": {\"a\": 1}, \"update\": {\"$set\": {\"b\": 2}}}}",
            collection: "orders", writeConcern: nil
        )
        #expect(update.kind == .update)
        #expect(update.touchesMany)
        #expect(update.document.contains("\"multi\": true"))

        let delete = try MongoScriptCommandBuilder.bulkOperation(
            "{\"deleteOne\": {\"filter\": {\"a\": 1}}}", collection: "orders", writeConcern: nil
        )
        #expect(delete.kind == .delete)
        #expect(!delete.touchesMany)
        #expect(delete.document.contains("\"limit\": 1"))
    }

    @Test("A bulk delete keeps its collation instead of dropping it")
    func bulkDeleteOptions() throws {
        let delete = try MongoScriptCommandBuilder.bulkOperation(
            "{\"deleteMany\": {\"filter\": {\"a\": 1}, \"collation\": {\"locale\": \"fr\"}}}",
            collection: "orders", writeConcern: nil
        )
        #expect(delete.touchesMany)
        #expect(delete.document.contains("\"collation\": {\"locale\":\"fr\"}"))
    }

    @Test("An unknown bulk operation is refused rather than silently skipped")
    func unknownBulkOperation() {
        #expect(throws: MongoScriptError.self) {
            try MongoScriptCommandBuilder.bulkOperation("{\"upsertAll\": {}}", collection: "orders", writeConcern: nil)
        }
    }
}

struct MongoScriptWriteConcernTests {
    private static let majority = "{\"w\": \"majority\"}"

    private static func occurrences(of field: String, in command: String) -> Int {
        command.components(separatedBy: field).count - 1
    }

    @Test("A statement that names no write concern takes the connection's")
    func connectionDefault() {
        #expect(MongoScriptCommandBuilder.writeConcern(statementOptions: nil, connectionDefault: Self.majority) == Self.majority)
        #expect(
            MongoScriptCommandBuilder.writeConcern(statementOptions: "{\"upsert\":true}", connectionDefault: Self.majority)
                == Self.majority
        )
    }

    @Test("The statement's own write concern wins over the connection's, as it does in mongosh")
    func statementWins() {
        let options = "{\"writeConcern\":{\"w\":{\"$numberInt\":\"1\"},\"wtimeout\":{\"$numberInt\":\"777\"}}}"
        #expect(
            MongoScriptCommandBuilder.writeConcern(statementOptions: options, connectionDefault: Self.majority)
                == "{\"w\": {\"$numberInt\":\"1\"}, \"wtimeout\": {\"$numberInt\":\"777\"}}"
        )
    }

    @Test("mongosh's journal and wtimeoutMS go out as the j and wtimeout the server reads")
    func mongoshSpellings() {
        let options = "{\"writeConcern\":{\"journal\":true,\"wtimeoutMS\":{\"$numberInt\":\"1000\"}}}"
        let canonical = "{\"j\": true, \"wtimeout\": {\"$numberInt\":\"1000\"}}"
        #expect(
            MongoScriptCommandBuilder.writeConcern(statementOptions: options, connectionDefault: Self.majority)
                == canonical
        )
        #expect(MongoScriptCommandBuilder.insertOptions(statementOptions: options) == "{\"writeConcern\": \(canonical)}")
    }

    @Test("Each name takes the first spelling set, in mongosh's order, and fsync stands for j")
    func spellingPrecedence() {
        let cases = [
            ("{\"writeConcern\":{\"journal\":true,\"j\":false}}", "{\"j\": false}"),
            ("{\"writeConcern\":{\"fsync\":true,\"w\":{\"$numberInt\":\"1\"}}}", "{\"w\": {\"$numberInt\":\"1\"}, \"j\": true}"),
            ("{\"writeConcern\":{\"wtimeoutMS\":9,\"wtimeout\":5}}", "{\"wtimeout\": 5}"),
            ("{\"writeConcern\":{\"j\":null,\"journal\":true}}", "{\"j\": true}")
        ]
        for (options, expected) in cases {
            #expect(MongoScriptCommandBuilder.writeConcern(statementOptions: options, connectionDefault: nil) == expected)
        }
    }

    @Test("A write concern naming none of w, j and wtimeout falls back to the connection's, as in mongosh")
    func emptyFallsBack() {
        for options in ["{\"writeConcern\":{}}", "{\"writeConcern\":{\"foo\":1}}", "{\"writeConcern\":{\"w\":null}}"] {
            #expect(
                MongoScriptCommandBuilder.writeConcern(statementOptions: options, connectionDefault: Self.majority)
                    == Self.majority
            )
            #expect(MongoScriptCommandBuilder.insertOptions(statementOptions: options) == nil)
        }
    }

    @Test("A write concern that names one field replaces the connection's whole, as in mongosh")
    func partialReplacesWhole() {
        #expect(
            MongoScriptCommandBuilder.writeConcern(
                statementOptions: "{\"writeConcern\":{\"wtimeoutMS\":{\"$numberInt\":\"555\"}}}",
                connectionDefault: Self.majority
            ) == "{\"wtimeout\": {\"$numberInt\":\"555\"}}"
        )
    }

    @Test("Only w: 0, or libmongoc's legacy w: -1, without j: true goes unacknowledged, in any number wrapper")
    func acknowledgement() {
        let unacknowledged = [
            "{\"w\": {\"$numberInt\":\"0\"}}",
            "{\"w\": {\"$numberDouble\":\"0.0\"}}",
            "{\"w\": {\"$numberInt\":\"0\"}, \"j\": false}",
            "{\"w\":{\"$numberInt\":\"0\"}}",
            "{\"w\": {\"$numberInt\":\"-1\"}}",
            "{\"w\": -1}"
        ]
        for concern in unacknowledged {
            #expect(!MongoScriptCommandBuilder.isAcknowledged(writeConcern: concern), "\(concern)")
        }
        let acknowledged = [
            nil,
            Self.majority,
            "{\"w\": {\"$numberInt\":\"1\"}}",
            "{\"w\": {\"$numberInt\":\"0\"}, \"j\": true}",
            "{\"w\": \"0\"}",
            "{\"w\": false}",
            "{\"j\": true}"
        ]
        for concern in acknowledged {
            #expect(MongoScriptCommandBuilder.isAcknowledged(writeConcern: concern), "\(String(describing: concern))")
        }
    }

    @Test("A statement's w: 0 decides acknowledgement the same way the connection's does")
    func statementWZero() {
        let concern = MongoScriptCommandBuilder.writeConcern(
            statementOptions: "{\"writeConcern\":{\"w\":{\"$numberInt\":\"0\"}}}", connectionDefault: Self.majority
        )
        #expect(!MongoScriptCommandBuilder.isAcknowledged(writeConcern: concern))
        #expect(!MongoScriptCommandBuilder.isAcknowledged(
            writeConcern: MongoScriptCommandBuilder.writeConcern(
                statementOptions: nil, connectionDefault: "{ \"w\" : { \"$numberInt\" : \"0\" } }"
            )
        ))
    }

    @Test("A null write concern counts as unset, the way mongosh reads it")
    func nullIsUnset() {
        let concern = MongoScriptCommandBuilder.writeConcern(
            statementOptions: "{\"writeConcern\":null}", connectionDefault: Self.majority
        )
        #expect(concern == Self.majority)
        let command = MongoScriptCommandBuilder.update(
            collection: "orders", filter: "{}", update: "{\"$set\":{}}", multi: false,
            options: [:], writeConcern: concern
        )
        #expect(Self.occurrences(of: "\"writeConcern\"", in: command) == 1)
        #expect(command.contains("\"writeConcern\": \(Self.majority)"))
    }

    @Test("With neither set, no write concern is sent and the server's default applies")
    func neitherSet() {
        #expect(MongoScriptCommandBuilder.writeConcern(statementOptions: nil, connectionDefault: nil) == nil)
        let command = MongoScriptCommandBuilder.delete(
            collection: "orders", filter: "{}", multi: true, options: [:], writeConcern: nil
        )
        #expect(!command.contains("writeConcern"))
    }

    @Test("Every write command carries the write concern exactly once, at the top level")
    func everyWriteCarriesIt() throws {
        let commands = [
            MongoScriptCommandBuilder.update(
                collection: "orders", filter: "{}", update: "{\"$set\":{}}", multi: true,
                options: [:], writeConcern: Self.majority
            ),
            MongoScriptCommandBuilder.delete(
                collection: "orders", filter: "{}", multi: false, options: [:], writeConcern: Self.majority
            ),
            MongoScriptCommandBuilder.findAndModify(
                collection: "orders", filter: "{}", update: "{\"$set\":{}}", remove: false,
                options: [:], writeConcern: Self.majority
            ),
            try MongoScriptCommandBuilder.bulkOperation(
                "{\"insertOne\": {\"document\": {\"a\": 1}}}", collection: "orders", writeConcern: Self.majority
            ).document,
            try MongoScriptCommandBuilder.bulkOperation(
                "{\"updateMany\": {\"filter\": {}, \"update\": {\"$set\": {\"b\": 2}}}}",
                collection: "orders", writeConcern: Self.majority
            ).document,
            try MongoScriptCommandBuilder.bulkOperation(
                "{\"deleteOne\": {\"filter\": {}}}", collection: "orders", writeConcern: Self.majority
            ).document
        ]
        for command in commands {
            #expect(Self.occurrences(of: "\"writeConcern\"", in: command) == 1)
            #expect(MongoScriptJson.member(of: command, key: "writeConcern") == Self.majority)
        }
    }

    @Test("An insert sends w: 0 beside j: true as w: 1, which libmongoc accepts and the server treats the same")
    func insertJournaledUnacknowledged() {
        let cases = [
            ("{\"writeConcern\":{\"w\":{\"$numberInt\":\"0\"},\"j\":true}}", "{\"w\": 1, \"j\": true}"),
            ("{\"writeConcern\":{\"w\":0,\"journal\":true,\"wtimeoutMS\":5}}", "{\"w\": 1, \"j\": true, \"wtimeout\": 5}"),
            ("{\"writeConcern\":{\"fsync\":true,\"w\":0}}", "{\"w\": 1, \"j\": true}"),
            ("{\"writeConcern\":{\"w\":0,\"j\":false}}", "{\"w\": 0, \"j\": false}"),
            ("{\"writeConcern\":{\"w\":-1,\"j\":true}}", "{\"w\": -1, \"j\": true}")
        ]
        for (options, concern) in cases {
            #expect(MongoScriptCommandBuilder.insertOptions(statementOptions: options) == "{\"writeConcern\": \(concern)}")
        }
        let commandConcern = MongoScriptCommandBuilder.writeConcern(
            statementOptions: "{\"writeConcern\":{\"w\":0,\"j\":true}}", connectionDefault: Self.majority
        )
        #expect(commandConcern == "{\"w\": 0, \"j\": true}")
        #expect(MongoScriptCommandBuilder.isAcknowledged(writeConcern: commandConcern))
    }

    @Test("An insert takes only the statement's own write concern and ordered flag")
    func insertOptions() {
        #expect(MongoScriptCommandBuilder.insertOptions(statementOptions: nil) == nil)
        #expect(MongoScriptCommandBuilder.insertOptions(statementOptions: "null") == nil)
        #expect(MongoScriptCommandBuilder.insertOptions(statementOptions: "{\"comment\":\"x\"}") == nil)
        #expect(
            MongoScriptCommandBuilder.insertOptions(
                statementOptions: "{\"ordered\":false,\"comment\":\"x\",\"writeConcern\":{\"w\":\"majority\"}}"
            ) == "{\"writeConcern\": {\"w\": \"majority\"}, \"ordered\": false}"
        )
        #expect(
            MongoScriptCommandBuilder.insertOptions(statementOptions: "{\"writeConcern\":null,\"ordered\":true}")
                == "{\"ordered\": true}"
        )
    }
}

struct MongoScriptObjectIdTests {
    @Test("A generated id is 24 lowercase hex characters")
    func shape() {
        let hex = MongoScriptObjectId.generate()
        #expect(hex.count == 24)
        #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("Two generated ids differ")
    func uniqueness() {
        let first = MongoScriptObjectId.generate()
        let second = MongoScriptObjectId.generate()
        #expect(first != second)
    }

    @Test("The leading four bytes are the current time")
    func timestampPrefix() throws {
        let hex = MongoScriptObjectId.generate()
        let seconds = try #require(UInt32(hex.prefix(8), radix: 16))
        #expect(abs(Double(seconds) - Date().timeIntervalSince1970) < 5)
    }

    @Test("Hex payloads decode, and odd-length ones are refused")
    func hexDecoding() {
        #expect(MongoScriptObjectId.data(fromHex: "00ff10")?.count == 3)
        #expect(MongoScriptObjectId.data(fromHex: "abc") == nil)
        #expect(MongoScriptObjectId.data(fromHex: "zz") == nil)
    }
}

struct MongoShellCommandLineTests {
    @Test("use becomes a call")
    func useBecomesCall() {
        #expect(MongoShellCommandLine.rewrite("use orders") == "use(\"orders\")")
        #expect(MongoShellCommandLine.rewrite("use orders;") == "use(\"orders\")")
        #expect(MongoShellCommandLine.rewrite("  use  orders  ") == "use(\"orders\")")
    }

    @Test("show becomes a call for the topics MongoDB has")
    func showBecomesCall() {
        #expect(MongoShellCommandLine.rewrite("show dbs") == "show(\"dbs\")")
        #expect(MongoShellCommandLine.rewrite("show collections") == "show(\"collections\")")
        #expect(MongoShellCommandLine.rewrite("SHOW TABLES") == "show(\"tables\")")
    }

    @Test("An unknown show topic is left alone")
    func unknownTopic() {
        #expect(MongoShellCommandLine.rewrite("show profile") == "show profile")
    }

    @Test("JavaScript that merely starts with the word is left alone")
    func javaScriptIsNotRewritten() {
        #expect(MongoShellCommandLine.rewrite("use = 1") == "use = 1")
        #expect(MongoShellCommandLine.rewrite("use(\"orders\")") == "use(\"orders\")")
        #expect(MongoShellCommandLine.rewrite("show.me()") == "show.me()")
        #expect(MongoShellCommandLine.rewrite("db.orders.find({})") == "db.orders.find({})")
    }

    @Test("A quoted database name loses its quotes rather than gaining a second pair")
    func quotedName() {
        #expect(MongoShellCommandLine.rewrite("use \"orders\"") == "use(\"orders\")")
    }
}

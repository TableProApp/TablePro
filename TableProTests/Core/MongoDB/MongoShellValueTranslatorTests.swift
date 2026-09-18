//
//  MongoShellValueTranslatorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MongoDB Shell Value Translator")
struct MongoShellValueTranslatorTests {
    private static let oid = "507f1f77bcf86cd799439011"
    private static let uuid = "8cd003eb-4a25-4324-9332-88fce2da0d1a"

    @Suite("Constructors")
    struct ConstructorTests {
        @Test("ObjectId becomes $oid")
        func objectId() throws {
            let result = try MongoShellValueTranslator.translate("{\"_id\": ObjectId(\"507f1f77bcf86cd799439011\")}")
            #expect(result == "{\"_id\": {\"$oid\": \"507f1f77bcf86cd799439011\"}}")
        }

        @Test("ISODate and Date become $date")
        func dates() throws {
            let iso = try MongoShellValueTranslator.translate("{at: ISODate(\"2026-01-01T00:00:00Z\")}")
            #expect(iso == "{at: {\"$date\": \"2026-01-01T00:00:00Z\"}}")
            let date = try MongoShellValueTranslator.translate("{at: Date(\"2026-01-01T00:00:00Z\")}")
            #expect(date == "{at: {\"$date\": \"2026-01-01T00:00:00Z\"}}")
        }

        @Test("Numeric helpers accept both quoted and bare arguments")
        func numbers() throws {
            #expect(try MongoShellValueTranslator.translate("NumberInt(42)") == "{\"$numberInt\": \"42\"}")
            #expect(try MongoShellValueTranslator.translate("NumberInt(\"42\")") == "{\"$numberInt\": \"42\"}")
            #expect(
                try MongoShellValueTranslator.translate("NumberLong(9007199254740993)")
                    == "{\"$numberLong\": \"9007199254740993\"}"
            )
            #expect(
                try MongoShellValueTranslator.translate("NumberDecimal(\"1.25\")")
                    == "{\"$numberDecimal\": \"1.25\"}"
            )
        }

        @Test("Timestamp becomes $timestamp")
        func timestamp() throws {
            let result = try MongoShellValueTranslator.translate("{ts: Timestamp(1700000000, 1)}")
            #expect(result == "{ts: {\"$timestamp\": {\"t\": 1700000000, \"i\": 1}}}")
        }

        @Test("BinData keeps its subtype")
        func binData() throws {
            let result = try MongoShellValueTranslator.translate("{b: BinData(5, \"3q2+7w==\")}")
            #expect(result == "{b: {\"$binary\": {\"base64\": \"3q2+7w==\", \"subType\": \"05\"}}}")
        }

        @Test("HexData converts to base64")
        func hexData() throws {
            let result = try MongoShellValueTranslator.translate("{b: HexData(0, \"deadbeef\")}")
            #expect(result == "{b: {\"$binary\": {\"base64\": \"3q2+7w==\", \"subType\": \"00\"}}}")
        }

        @Test("MinKey and MaxKey work with and without parentheses")
        func extremeKeys() throws {
            #expect(try MongoShellValueTranslator.translate("{a: MinKey}") == "{a: {\"$minKey\": 1}}")
            #expect(try MongoShellValueTranslator.translate("{a: MinKey()}") == "{a: {\"$minKey\": 1}}")
            #expect(try MongoShellValueTranslator.translate("{a: MaxKey}") == "{a: {\"$maxKey\": 1}}")
        }

        @Test("The UUID family routes through the shared codec")
        func uuidFamily() throws {
            let standard = try MongoShellValueTranslator.translate("UUID(\"8cd003eb-4a25-4324-9332-88fce2da0d1a\")")
            #expect(standard == "{\"$binary\": {\"base64\": \"jNAD60olQySTMoj84toNGg==\", \"subType\": \"04\"}}")

            let java = try MongoShellValueTranslator
                .translate("LegacyJavaUUID(\"8cd003eb-4a25-4324-9332-88fce2da0d1a\")")
            #expect(java == "{\"$binary\": {\"base64\": \"JEMlSusD0IwaDdri/Igykw==\", \"subType\": \"03\"}}")

            let alias = try MongoShellValueTranslator.translate("JUUID(\"8cd003eb-4a25-4324-9332-88fce2da0d1a\")")
            #expect(alias == java)
        }
    }

    @Suite("Scanning")
    struct ScanningTests {
        /// A method call is always preceded by a dot; a constructor never is.
        @Test("Method names that look like helpers are left alone")
        func methodsAreNotTranslated() throws {
            let input = "db.users.find({}).sort({a: 1}).limit(10)"
            #expect(try MongoShellValueTranslator.translate(input) == input)
        }

        @Test("A helper inside a double-quoted string is not translated")
        func doubleQuotedStringsAreInert() throws {
            let input = "{name: \"ObjectId(\\\"abc\\\")\"}"
            #expect(try MongoShellValueTranslator.translate(input) == input)
        }

        @Test("A helper inside a single-quoted string is not translated")
        func singleQuotedStringsAreInert() throws {
            let input = "{name: 'MinKey and ISODate(1)'}"
            #expect(try MongoShellValueTranslator.translate(input) == input)
        }

        @Test("A field literally named like a helper is untouched")
        func fieldNamesAreInert() throws {
            let input = "{\"ObjectId\": 1, \"MinKey\": 2}"
            #expect(try MongoShellValueTranslator.translate(input) == input)
        }

        @Test("Helpers nested in arrays and subdocuments are translated")
        func nestedHelpers() throws {
            let result = try MongoShellValueTranslator.translate(
                "{$or: [{_id: ObjectId(\"507f1f77bcf86cd799439011\")}, {n: NumberInt(1)}]}"
            )
            #expect(result == "{$or: [{_id: {\"$oid\": \"507f1f77bcf86cd799439011\"}}, {n: {\"$numberInt\": \"1\"}}]}")
        }

        @Test("Translation is idempotent")
        func idempotent() throws {
            let once = try MongoShellValueTranslator.translate(
                "db.c.find({_id: ObjectId(\"507f1f77bcf86cd799439011\"), at: ISODate(\"2026-01-01T00:00:00Z\")})"
            )
            #expect(try MongoShellValueTranslator.translate(once) == once)
        }

        @Test("Text with no helper is returned unchanged")
        func passthrough() throws {
            let input = "db.users.find({age: {$gt: 21}}).limit(5)"
            #expect(try MongoShellValueTranslator.translate(input) == input)
        }

        @Test("An unknown constructor is left for the driver to reject")
        func unknownConstructorUntouched() throws {
            let input = "{a: SomethingElse(1)}"
            #expect(try MongoShellValueTranslator.translate(input) == input)
        }
    }

    @Suite("Errors")
    struct ErrorTests {
        @Test("A malformed ObjectId is rejected by name")
        func badObjectId() {
            #expect(throws: MongoShellValueError.malformedArguments(helper: "ObjectId")) {
                try MongoShellValueTranslator.translate("{_id: ObjectId(\"nope\")}")
            }
        }

        @Test("A non-numeric NumberInt is rejected")
        func badNumber() {
            #expect(throws: MongoShellValueError.malformedArguments(helper: "NumberInt")) {
                try MongoShellValueTranslator.translate("{n: NumberInt(\"abc\")}")
            }
        }

        @Test("An out-of-range NumberInt is rejected")
        func overflowingNumber() {
            #expect(throws: MongoShellValueError.malformedArguments(helper: "NumberInt")) {
                try MongoShellValueTranslator.translate("{n: NumberInt(99999999999)}")
            }
        }

        @Test("A helper missing its closing parenthesis is reported")
        func unterminatedCall() {
            #expect(throws: MongoShellValueError.unterminatedCall(helper: "ObjectId")) {
                try MongoShellValueTranslator.translate("{_id: ObjectId(\"507f1f77bcf86cd799439011\"")
            }
        }

        @Test("An unterminated string is reported once a helper puts the scanner to work")
        func unterminatedString() {
            #expect(throws: MongoShellValueError.unterminatedString) {
                try MongoShellValueTranslator
                    .translate("{a: ObjectId(\"507f1f77bcf86cd799439011\"), name: \"oops}")
            }
        }

        /// The translator is not a JSON validator: text carrying no helper is handed to the
        /// driver untouched so libbson reports the syntax error.
        @Test("Malformed text with no helper is passed through rather than rejected here")
        func malformedTextWithoutHelperPassesThrough() throws {
            let input = "{name: \"oops}"
            #expect(try MongoShellValueTranslator.translate(input) == input)
        }
    }

    @Suite("Parser integration")
    struct ParserIntegrationTests {
        @Test("A find filter carrying ObjectId reaches the driver as Extended JSON")
        func findFilter() throws {
            let operation = try MongoShellParser.parse(
                "db.users.find({_id: ObjectId(\"507f1f77bcf86cd799439011\")})"
            )
            guard case .find(let collection, let filter, _) = operation else {
                Issue.record("expected a find operation")
                return
            }
            #expect(collection == "users")
            #expect(filter.contains("\"$oid\""))
            #expect(!filter.contains("ObjectId("))
        }

        @Test("A UUID pasted from the grid is accepted in a filter")
        func uuidFilter() throws {
            let operation = try MongoShellParser.parse(
                "db.docs.find({ref: LegacyJavaUUID(\"8cd003eb-4a25-4324-9332-88fce2da0d1a\")})"
            )
            guard case .find(_, let filter, _) = operation else {
                Issue.record("expected a find operation")
                return
            }
            #expect(filter.contains("\"subType\": \"03\""))
        }

        @Test("A helper inside sort is translated too")
        func sortOption() throws {
            let operation = try MongoShellParser.parse(
                "db.docs.find({}).sort({at: NumberInt(-1)})"
            )
            guard case .find(_, _, let options) = operation else {
                Issue.record("expected a find operation")
                return
            }
            #expect(options.sort?.contains("$numberInt") == true)
        }

        @Test("A runCommand payload is translated")
        func runCommand() throws {
            let operation = try MongoShellParser.parse(
                "db.runCommand({find: \"c\", filter: {_id: ObjectId(\"507f1f77bcf86cd799439011\")}})"
            )
            guard case .runCommand(let command) = operation else {
                Issue.record("expected a runCommand operation")
                return
            }
            #expect(command.contains("\"$oid\""))
        }
    }
}

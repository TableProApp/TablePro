import Foundation
@testable import TableProMobile
import TableProPluginKit
import Testing

struct MongoDBStringFieldWriteTests {
    private static let locator = #"{"$oid":"507f1f77bcf86cd799439011"}"#

    private func statement(
        editing old: String,
        to new: String,
        held: Set<BsonValueKind>?
    ) throws -> String {
        var generator = MongoDBStatementGenerator(collectionName: "places", columns: ["_id", "zip"])
        generator.rowLocators = [0: Self.locator]
        if let held {
            generator.fieldKinds = MongoDBFieldKinds(["zip": held])
        }
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(1, "zip", .text(old), .text(new))],
            originalRow: [.text("507f1f77bcf86cd799439011"), .text(old)]
        )
        let writes = try generator.generateRowWrites(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        return try #require(writes.first?.statement)
    }

    @Test(
        "Text that reads as a number, a boolean or null stays a string in a field that held only strings",
        arguments: ["90211", "-1.5", "true", "false", "null"]
    )
    func stringFieldKeepsStrings(text: String) throws {
        let statement = try statement(editing: "90210", to: text, held: [.string])
        #expect(statement.contains(#""zip": "\#(text)""#))
    }

    @Test("A string field that also held nulls still stores number text as a string")
    func stringAndNullField() throws {
        let statement = try statement(editing: "90210", to: "90211", held: [.string, .null])
        #expect(statement.contains(#""zip": "90211""#))
    }

    @Test("A field that held numbers beside strings keeps reading number text as a number")
    func mixedFieldInfersByShape() throws {
        let statement = try statement(editing: "90210", to: "90211", held: [.string, .int32])
        #expect(statement.contains(#""zip": 90211"#))
    }

    @Test("A field that held booleans beside strings keeps reading true as a boolean")
    func mixedBooleanField() throws {
        let statement = try statement(editing: "x", to: "true", held: [.string, .boolean])
        #expect(statement.contains(#""zip": true"#))
    }

    @Test("A field nothing was read from keeps reading number text as a number")
    func unknownFieldInfersByShape() throws {
        let statement = try statement(editing: "90210", to: "90211", held: nil)
        #expect(statement.contains(#""zip": 90211"#))
    }

    @Test("A new document stores number text as a string in a field that held only strings")
    func insertIntoStringField() throws {
        var generator = MongoDBStatementGenerator(collectionName: "places", columns: ["_id", "zip"])
        generator.fieldKinds = MongoDBFieldKinds(["zip": [.string]])
        let change = PluginRowChange(
            rowIndex: 0, type: .insert, cellChanges: [(1, "zip", .null, .text("90211"))], originalRow: nil
        )
        let writes = try generator.generateRowWrites(
            from: [change], insertedRowData: [0: [.null, .text("90211")]], deletedRowIndices: [], insertedRowIndices: [0]
        )
        let statement = try #require(writes.first?.statement)
        #expect(statement.contains(#""zip": "90211""#))
    }
}

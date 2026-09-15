//
//  DynamoDBOperationsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("DynamoDB table operations")
struct DynamoDBOperationsTests {
    @Test("Dropping a table produces a statement the driver recognises")
    func dropIsRecognised() throws {
        let statement = try #require(DynamoDBOperations.dropTable(named: "orders", objectType: "TABLE"))
        #expect(statement == "DROP TABLE \"orders\"")
        #expect(DynamoDBOperations.droppedTableName(in: statement) == "orders")
    }

    /// The statement is shown in the confirmation and then run, so a statement the driver's own
    /// dispatch does not route would be #2884 in a third engine.
    @Test("Every generated drop round-trips back to its table name", arguments: [
        "orders", "my-table", "my_table", "my.table", "Orders2024",
    ])
    func dropRoundTrips(name: String) throws {
        let statement = try #require(DynamoDBOperations.dropTable(named: name, objectType: "TABLE"))
        #expect(DynamoDBOperations.droppedTableName(in: statement) == name)
    }

    /// A DynamoDB table name is 3 to 255 characters of letters, digits, underscore, hyphen and dot.
    /// A name holding anything else did not come from the table listing.
    @Test("A name DynamoDB could not have is refused", arguments: [
        "", "ab", "has space", "has\"quote", "semi;colon", "star*", "slash/y",
    ])
    func invalidNamesRefused(name: String) {
        #expect(DynamoDBOperations.dropTable(named: name, objectType: "TABLE") == nil)
    }

    @Test("Only a table is droppable", arguments: ["VIEW", "MATERIALIZED VIEW", "FOREIGN TABLE"])
    func onlyTablesAreDroppable(objectType: String) {
        #expect(DynamoDBOperations.dropTable(named: "orders", objectType: objectType) == nil)
    }

    @Test("Text that is not a drop statement routes nowhere", arguments: [
        "SELECT * FROM \"orders\"", "DROP TABLE orders", "DROP TABLE \"\"", "DELETE FROM \"orders\"", "",
    ])
    func nonDropStatementsAreNotRouted(statement: String) {
        #expect(DynamoDBOperations.droppedTableName(in: statement) == nil)
    }

    /// PartiQL has no DDL, so this text is the driver's own vocabulary. It is spelled `DROP TABLE`
    /// partly so the generic SQL classifier tiers it destructive without a DynamoDB arm.
    @Test("A drop reads as destructive")
    func dropClassifiesDestructive() throws {
        let statement = try #require(DynamoDBOperations.dropTable(named: "orders", objectType: "TABLE"))
        #expect(QueryClassifier.classify(statement, databaseType: .dynamodb).tier == .destructive)
    }
}

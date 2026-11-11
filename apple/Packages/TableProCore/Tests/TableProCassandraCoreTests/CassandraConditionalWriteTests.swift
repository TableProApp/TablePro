//
//  CassandraConditionalWriteTests.swift
//  TableProCassandraCoreTests
//

import TableProCassandraCore
import Testing

struct CassandraConditionalWriteTests {
    private static let update = CassandraConditionalWrite.updateStatement(
        target: "\"shop\".\"orders\"", assignments: ["\"note\" = ?"], keyCondition: "\"id\" = ?"
    )
    private static let insert = CassandraConditionalWrite.insertStatement(
        target: "\"shop\".\"orders\"", names: ["\"id\"", "\"note\""], values: ["?", "?"]
    )

    // Without the condition CQL writes the cell anyway and recreates the row with every other column null.
    @Test("A grid edit only writes a row that still exists")
    func updateIsConditionedOnTheRow() {
        #expect(Self.update == "UPDATE \"shop\".\"orders\" SET \"note\" = ? WHERE \"id\" = ? IF EXISTS")
        #expect(Self.insert == "INSERT INTO \"shop\".\"orders\" (\"id\", \"note\") VALUES (?, ?) IF NOT EXISTS")
    }

    @Test("An edit of a row deleted since it was read is refused, not reported as saved")
    func updateOfAMissingRowIsRefused() {
        #expect(CassandraConditionalWrite.refusal(
            statement: Self.update, firstColumn: "[applied]", firstValue: "false"
        ) == .rowMissing)
    }

    @Test("A new row whose key is taken is refused")
    func insertOfATakenKeyIsRefused() {
        #expect(CassandraConditionalWrite.refusal(
            statement: Self.insert, firstColumn: "[applied]", firstValue: "false"
        ) == .keyTaken)
    }

    @Test("A write the condition let through is no refusal")
    func appliedWriteIsNotRefused() {
        #expect(CassandraConditionalWrite.refusal(
            statement: Self.update, firstColumn: "[applied]", firstValue: "true"
        ) == nil)
        #expect(CassandraConditionalWrite.refusal(
            statement: Self.insert, firstColumn: "[applied]", firstValue: "true"
        ) == nil)
    }

    // A condition on a column answers with the row's current values, which the console shows as the server sent them.
    @Test("An unapplied write with a condition of its own is left to the result")
    func otherConditionsAreLeftToTheResult() {
        #expect(CassandraConditionalWrite.refusal(
            statement: "UPDATE t SET a = 1 WHERE k = 1 IF a = 0", firstColumn: "[applied]", firstValue: "false"
        ) == nil)
        #expect(CassandraConditionalWrite.refusal(
            statement: "DELETE FROM t WHERE k = 1 IF EXISTS", firstColumn: "[applied]", firstValue: "false"
        ) == nil)
        #expect(CassandraConditionalWrite.refusal(
            statement: "UPDATE t SET a = 1 WHERE k = 1", firstColumn: "a", firstValue: "false"
        ) == nil)
    }
}

//
//  ScriptResultEncoderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ScriptResultEncoderTests {
    private func rows(of record: [String: Any]) throws -> [[String]] {
        let raw = try #require(record[ScriptingKeys.QueryResult.rows] as? [[String: Any]])
        return try raw.map { try #require($0[ScriptingKeys.ResultRow.values] as? [String]) }
    }

    @Test("A result becomes a record whose rows are records of text")
    func encodesRowsAsRecords() throws {
        let result = QueryResult(
            columns: ["id", "name"],
            columnTypes: [],
            rows: [
                [.text("1"), .text("alice")],
                [.text("2"), .text("bob")]
            ],
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )

        let record = ScriptResultEncoder.encode(.statement(result, executionTimeMs: 12.5))

        #expect(record[ScriptingKeys.QueryResult.columns] as? [String] == ["id", "name"])
        #expect(record[ScriptingKeys.QueryResult.rowCount] as? Int == 2)
        #expect(record[ScriptingKeys.QueryResult.executionTime] as? Double == 12.5)
        #expect(try rows(of: record) == [["1", "alice"], ["2", "bob"]])
    }

    /// AppleScript has no null and no typed cell, so both have to become text. Base64 is the same
    /// spelling the MCP surface uses, so a script and a tool describe a blob the same way.
    @Test("A null becomes empty text and binary becomes Base64")
    func encodesNullAndBinary() throws {
        let payload = Data([0x01, 0x02, 0x03])
        let result = QueryResult(
            columns: ["nothing", "blob"],
            columnTypes: [],
            rows: [[.null, .bytes(payload)]],
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )

        let record = ScriptResultEncoder.encode(.statement(result, executionTimeMs: 0))

        #expect(try rows(of: record) == [["", payload.base64EncodedString()]])
    }

    @Test("Every declared field is present, so a script never reads a missing property")
    func alwaysCarriesEveryField() throws {
        let record = ScriptResultEncoder.empty()
        for key in ScriptingKeys.QueryResult.all {
            #expect(record[key] != nil, "'\(key)' is missing from an empty result")
        }
        #expect(record[ScriptingKeys.QueryResult.rowCount] as? Int == 0)
        #expect(record[ScriptingKeys.QueryResult.statusMessage] as? String == "")
    }

    /// A tab's rows come with the result set's own metadata. Answering these four with defaults
    /// described a capped read as complete and a DML statement as having changed nothing.
    @Test("A tab result carries the result set's metadata rather than defaults")
    func tabResultsCarryTheirMetadata() throws {
        let read = DisplayedResultReader.Output(
            columns: ["id"],
            columnTypes: [],
            rows: [[.text("1")]],
            skippedDeletedCount: 0
        )
        let record = ScriptResultEncoder.encode(
            read,
            metadata: ScriptResultEncoder.Metadata(
                rowsAffected: 3,
                truncated: true,
                executionTimeMs: 42,
                statusMessage: "UPDATE 3"
            )
        )

        #expect(record[ScriptingKeys.QueryResult.rowsAffected] as? Int == 3)
        #expect(record[ScriptingKeys.QueryResult.truncated] as? Bool == true)
        #expect(record[ScriptingKeys.QueryResult.executionTime] as? Double == 42)
        #expect(record[ScriptingKeys.QueryResult.statusMessage] as? String == "UPDATE 3")
        #expect(try rows(of: record) == [["1"]])
    }

    /// The record is the first result, as it always was, so a script written before scripts existed reads the same
    /// thing. `results` holds every result set of a SQL Server script that returned more than one (#3078).
    @Test("A script's record is its first result set and lists every result set in results")
    func scriptListsEveryResultSet() throws {
        let outcome = ScriptBatchRun(
            answers: [
                QueryBatchResult(
                    resultSets: [
                        ScriptAnsweringDriver.resultSet(columns: ["a"], rows: [["1"]]),
                        ScriptAnsweringDriver.resultSet(columns: ["b", "c"], rows: [["x", "y"]], isTruncated: true)
                    ],
                    rowsAffected: 4,
                    errors: [],
                    discardedResultSetCount: 0,
                    executionTime: 0
                )
            ],
            sessionState: .idle
        ).outcome(executionTimeMs: 9)

        let record = ScriptResultEncoder.encode(outcome)

        #expect(record[ScriptingKeys.QueryResult.columns] as? [String] == ["a"])
        #expect(record[ScriptingKeys.QueryResult.rowsAffected] as? Int == 4)
        let results = try #require(record[ScriptingKeys.QueryResult.results] as? [[String: Any]])
        #expect(results.map { $0[ScriptingKeys.QueryResult.columns] as? [String] } == [["a"], ["b", "c"]])
        #expect(try rows(of: results[1]) == [["x", "y"]])
        #expect(results.map { $0[ScriptingKeys.QueryResult.truncated] as? Bool } == [false, true])
        for key in ScriptingKeys.ResultSet.all {
            #expect(results.allSatisfy { $0[key] != nil }, "'\(key)' is missing from a result set")
        }
    }

    @Test("A single result leaves results empty rather than repeating the rows")
    func singleResultLeavesResultsEmpty() throws {
        let result = QueryResult(
            columns: ["n"],
            columnTypes: [],
            rows: [[.text("1")]],
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )

        let record = ScriptResultEncoder.encode(.statement(result, executionTimeMs: 1))

        let results = try #require(record[ScriptingKeys.QueryResult.results] as? [[String: Any]])
        #expect(results.isEmpty)
    }

    @Test("A statement that changed rows reports how many, and whether it was cut short")
    func carriesAffectedAndTruncated() throws {
        var result = QueryResult(
            columns: [],
            columnTypes: [],
            rows: [],
            rowsAffected: 7,
            executionTime: 0,
            error: nil
        )
        result.isTruncated = true
        result.statusMessage = "UPDATE 7"

        let record = ScriptResultEncoder.encode(.statement(result, executionTimeMs: 3))

        #expect(record[ScriptingKeys.QueryResult.rowsAffected] as? Int == 7)
        #expect(record[ScriptingKeys.QueryResult.truncated] as? Bool == true)
        #expect(record[ScriptingKeys.QueryResult.statusMessage] as? String == "UPDATE 7")
    }
}

//
//  AgentResultDecoderTests.swift
//  TableProTests
//
//  The decoder used to answer with an optional, and the pane said "This query returned no rows." for
//  every nil: an approved UPDATE, a reply it could not read, and a query that really did match
//  nothing. Each of those is a different thing to tell someone.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct AgentResultDecoderTests {
    private func payload(_ json: String) -> AgentResultPayload {
        AgentResultDecoder.payload(fromResultJSON: json)
    }

    @Test("A result set with rows decodes to rows")
    func rowsDecode() throws {
        let decoded = payload(#"{"columns":["id","name"],"rows":[[1,"Ada"],[2,null]],"row_count":2,"rows_affected":0}"#)

        guard case .rows(let rows) = decoded else {
            Issue.record("Expected rows, got \(decoded)")
            return
        }
        #expect(rows.columns == ["id", "name"])
        #expect(rows.count == 2)
        #expect(rows.value(at: 0, column: 1) == .text("Ada"))
        #expect(rows.value(at: 1, column: 1) == .null)
    }

    /// The columns are what separate the two: a query that matched nothing still names them.
    @Test("A named result set with no rows is an empty query, not a write")
    func emptyResultSet() {
        guard case .noRows = payload(#"{"columns":["id"],"rows":[],"row_count":0,"rows_affected":0}"#) else {
            Issue.record("A result set with columns and no rows is a query that returned no rows")
            return
        }
    }

    @Test("A statement with no result set carries the rows it changed")
    func writeCarriesItsCount() {
        guard case .completed(let rowsAffected) = payload(#"{"columns":[],"rows":[],"row_count":0,"rows_affected":3}"#)
        else {
            Issue.record("A reply with no columns is a statement that returned no result set")
            return
        }
        #expect(rowsAffected == 3)
    }

    @Test("A statement that reports no count still reads as completed")
    func writeWithoutACount() {
        guard case .completed(let rowsAffected) = payload(#"{"columns":[],"rows":[]}"#) else {
            Issue.record("A reply with no columns is a statement that returned no result set")
            return
        }
        #expect(rowsAffected == nil)
    }

    @Test(
        "A reply the grid cannot read says so",
        arguments: [
            "not json at all",
            "[1, 2, 3]",
            #"{"rows":[[1]]}"#,
            #"{"columns":["id"]}"#,
            #"{"columns":[],"rows":[[1]]}"#,
            #"{"columns":["id"],"rows":[1]}"#,
        ]
    )
    func unreadableReplies(_ json: String) {
        guard case .unreadable = payload(json) else {
            Issue.record("Expected \(json) to be unreadable")
            return
        }
    }
}

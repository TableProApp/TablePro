//
//  DashboardTilePolicyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct DashboardTilePolicyTests {
    @Test("A single read runs", arguments: [
        "SELECT count(*) FROM jobs WHERE state = 'queued'",
        "  -- queue depth\nSELECT 1",
        "WITH q AS (SELECT * FROM jobs) SELECT count(*) FROM q",
    ])
    func readRuns(sql: String) {
        #expect(DashboardTilePolicy.refusal(for: sql, databaseType: .postgresql, forcesWrite: false) == nil)
    }

    @Test("A write, a drop and a DDL statement are refused", arguments: [
        "UPDATE jobs SET state = 'done'",
        "DELETE FROM jobs",
        "DROP TABLE jobs",
        "CREATE TABLE t (id int)",
    ])
    func writeIsRefused(sql: String) {
        #expect(
            DashboardTilePolicy.refusal(for: sql, databaseType: .postgresql, forcesWrite: false)
                == String(localized: "This saved query is not a read. Tiles run reads only.")
        )
    }

    @Test("A write behind an executable comment is refused", arguments: [
        "WITH c AS (SELECT 1) /*m! ' */ DELETE FROM orders -- '",
        "WITH c AS (SELECT 1) /*!99999 ' */ DELETE FROM orders -- '",
        "SELECT * FROM orders /*m! ' */ INTO OUTFILE '/tmp/x' -- '",
    ])
    func hiddenWriteIsRefused(sql: String) {
        #expect(DashboardTilePolicy.refusal(for: sql, databaseType: .mysql, forcesWrite: false) != nil)
    }

    @Test("Two statements are refused, even when both read")
    func multipleStatementsAreRefused() {
        #expect(
            DashboardTilePolicy.refusal(for: "SELECT 1; SELECT 2", databaseType: .mysql, forcesWrite: false)
                == String(localized: "This saved query holds more than one statement. A tile runs one.")
        )
    }

    @Test("An empty saved query is refused")
    func emptyIsRefused() {
        #expect(DashboardTilePolicy.refusal(for: " \n ", databaseType: .mysql, forcesWrite: false) != nil)
    }

    @Test("An engine that cannot run a statement read-only refuses every tile")
    func forcedWriteEngineIsRefused() {
        #expect(
            DashboardTilePolicy.refusal(for: "SELECT 1", databaseType: .postgresql, forcesWrite: true)
                == String(localized: "This database cannot run a statement read-only, so tiles do not run on it.")
        )
    }

    @Test("A read that reaches the file system is refused")
    func fileSystemReadIsRefused() {
        let refusal = DashboardTilePolicy.refusal(
            for: "SELECT pg_read_file('/etc/passwd')",
            databaseType: .postgresql,
            forcesWrite: false
        )
        #expect(refusal == String(localized: "This saved query reads or writes files or runs server-side code. Tiles run reads only."))
    }
}

//
//  MySQLKillTargetTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MySQLKillTargetTests {
    @Test("Each target names its own kill, and only KILL <id> ends the session")
    func statementsAndSessionScope() {
        #expect(MySQLKillTarget.threadId.statement(threadId: 42) == "KILL QUERY 42")
        #expect(MySQLKillTarget.connection.statement(threadId: 42) == "KILL 42")
        #expect(MySQLKillTarget.tidbConnection(2_199_023_255_571).statement(threadId: 19) == "KILL TIDB QUERY 2199023255571")
        #expect(MySQLKillTarget.databendSession("s1").statement(threadId: 89) == "KILL QUERY 's1'")

        #expect(MySQLKillTarget.connection.endsSession)
        #expect(!MySQLKillTarget.threadId.endsSession)
        #expect(!MySQLKillTarget.tidbConnection(2_199_023_255_571).endsSession)
        #expect(!MySQLKillTarget.databendSession("s1").endsSession)
    }

    @Test("Thread id 0 names no session to kill")
    func zeroThreadId() {
        #expect(MySQLKillTarget.threadId.statement(threadId: 0) == nil)
        #expect(MySQLKillTarget.connection.statement(threadId: 0) == nil)
    }

    /// 4.1.22 answers `KILL QUERY` with `1204`, and 5.0.96 takes it.
    @Test("MySQL and MariaDB below 5.0 stop a statement only by ending its session")
    func legacyServersKillTheConnection() {
        #expect(MySQLServerFlavor.mysql.killTarget(connectionIdentifier: nil, banner: "4.1.22-standard") == .connection)
        #expect(MySQLServerFlavor.mariadb.killTarget(connectionIdentifier: nil, banner: "4.1.22") == .connection)
        for banner in ["5.0.0", "5.0.96", "5.1.73", "8.4.11"] {
            #expect(MySQLServerFlavor.mysql.killTarget(connectionIdentifier: nil, banner: banner) == .threadId)
        }
        #expect(MySQLServerFlavor.mariadb.killTarget(connectionIdentifier: nil, banner: "10.6.28-MariaDB") == .threadId)
    }

    @Test("An unreadable banner keeps KILL QUERY")
    func unreadableBannerKeepsKillQuery() {
        #expect(MySQLServerFlavor.mysql.killTarget(connectionIdentifier: nil, banner: nil) == .threadId)
        #expect(MySQLServerFlavor.mysql.killTarget(connectionIdentifier: nil, banner: "unknown") == .threadId)
    }

    @Test("TiDB, Databend and OceanBase keep their own kill whatever the banner says")
    func variantsAreNeverLegacy() {
        #expect(MySQLServerFlavor.tidb(version: nil).killTarget(connectionIdentifier: "2199023255571", banner: "4.1.22")
            == .tidbConnection(2_199_023_255_571))
        #expect(MySQLServerFlavor.databend.killTarget(connectionIdentifier: "s1", banner: "4.1.22") == .databendSession("s1"))
        #expect(MySQLServerFlavor.oceanbase(version: nil).killTarget(connectionIdentifier: nil, banner: "4.1.22") == .threadId)
    }
}

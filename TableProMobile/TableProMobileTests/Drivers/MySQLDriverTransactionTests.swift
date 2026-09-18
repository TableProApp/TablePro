import CMariaDB
import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

@Suite("MySQL transaction access mode on iOS")
struct MySQLDriverTransactionTests {
    private func readWriteStatement(type: DatabaseType, banner: String?) -> String {
        MySQLDriver.serverFlavor(for: type, banner: banner).beginTransactionStatement(mode: .readWrite)
    }

    @Test("MySQL and MariaDB get the version-gated read-write clause")
    func versionGatedClause() {
        #expect(readWriteStatement(type: .mysql, banner: "8.4.11") == "START TRANSACTION /*!50605 READ WRITE */")
        #expect(readWriteStatement(type: .mysql, banner: "5.7.44") == "START TRANSACTION /*!50605 READ WRITE */")
        #expect(
            readWriteStatement(type: .mariadb, banner: "10.6.28-MariaDB-ubu2204")
                == "START TRANSACTION /*!50605 READ WRITE */"
        )
    }

    @Test("TiDB and OceanBase take the plain read-write clause even without a banner")
    func plainClauseForForks() {
        #expect(readWriteStatement(type: .tidb, banner: nil) == "START TRANSACTION READ WRITE")
        #expect(readWriteStatement(type: .oceanbase, banner: nil) == "START TRANSACTION READ WRITE")
    }

    @Test("A TiDB banner on a MySQL connection still resolves to TiDB")
    func tidbBannerOnMySQLType() {
        #expect(readWriteStatement(type: .mysql, banner: "8.0.11-TiDB-v8.5.0") == "START TRANSACTION READ WRITE")
        #expect(MySQLDriver.serverFlavor(for: .mysql, banner: "8.0.11-TiDB-v8.5.0").tidbVersion?.major == 8)
    }

    @Test("Databend opens a plain BEGIN in either mode")
    func databendBegin() {
        let flavor = MySQLDriver.serverFlavor(for: .mysql, banner: "8.0.17-v1.2.615-nightly")
        #expect(flavor.beginTransactionStatement(mode: .readWrite) == "BEGIN")
        #expect(flavor.beginTransactionStatement(mode: .serverDefault) == "BEGIN")
    }

    @Test("The server default mode sends no access mode at all")
    func serverDefaultMode() {
        for type in [DatabaseType.mysql, .mariadb, .tidb, .oceanbase] {
            let flavor = MySQLDriver.serverFlavor(for: type, banner: nil)
            #expect(flavor.beginTransactionStatement(mode: .serverDefault) == "START TRANSACTION")
        }
    }

    @Test("The banner supplies the fork version the flavor carries")
    func forkVersionsComeFromTheBanner() {
        #expect(
            MySQLDriver.serverFlavor(for: .tidb, banner: "8.0.11-TiDB-v8.5.0")
                == .tidb(version: MySQLEngineVersion(major: 8, minor: 5, patch: 0))
        )
        #expect(
            MySQLDriver.serverFlavor(for: .oceanbase, banner: "5.7.25-OceanBase_CE-v4.2.1")
                == .oceanbase(version: MySQLEngineVersion(major: 4, minor: 2, patch: 1))
        )
        #expect(MySQLDriver.serverFlavor(for: .oceanbase, banner: "5.7.25") == .oceanbase(version: nil))
    }
}

@Suite("MySQL session transaction state")
struct MySQLSessionTransactionTests {
    private let inTransaction = UInt32(SERVER_STATUS_IN_TRANS)
    private let autocommit = UInt32(SERVER_STATUS_AUTOCOMMIT)

    @Test("A reply the client could not read leaves the state unknown")
    func unreadableReply() {
        #expect(MySQLSessionTransaction.state(infoResult: 1, serverStatus: autocommit) == .unknown)
        #expect(MySQLSessionTransaction.state(infoResult: 1, serverStatus: inTransaction | autocommit) == .unknown)
    }

    @Test("A fresh autocommit session is idle")
    func autocommitSessionIsIdle() {
        #expect(MySQLSessionTransaction.state(infoResult: 0, serverStatus: autocommit) == .idle)
    }

    @Test("A transaction the user opened under autocommit is explicit")
    func userTransactionIsExplicit() {
        #expect(
            MySQLSessionTransaction.state(infoResult: 0, serverStatus: inTransaction | autocommit)
                == .explicitTransaction
        )
    }

    @Test("A transaction the server opened because autocommit is off is implicit")
    func autocommitOffTransactionIsImplicit() {
        #expect(MySQLSessionTransaction.state(infoResult: 0, serverStatus: inTransaction) == .implicitTransaction)
    }

    @Test("Autocommit off with nothing started yet is idle")
    func autocommitOffBeforeAnyStatementIsIdle() {
        #expect(MySQLSessionTransaction.state(infoResult: 0, serverStatus: 0) == .idle)
    }

    @Test("Unrelated status bits do not change the answer")
    func unrelatedBitsAreIgnored() {
        let noBackslashEscapes = UInt32(SERVER_STATUS_NO_BACKSLASH_ESCAPES)
        #expect(
            MySQLSessionTransaction.state(infoResult: 0, serverStatus: autocommit | noBackslashEscapes) == .idle
        )
        #expect(
            MySQLSessionTransaction.state(
                infoResult: 0, serverStatus: inTransaction | autocommit | noBackslashEscapes
            ) == .explicitTransaction
        )
    }
}

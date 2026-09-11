//
//  SQLStatementSplittingTests.swift
//  TableProTests
//

import Foundation
import Testing
import TableProPluginKit

@Suite("SQL statement splitting")
struct SQLStatementSplittingTests {
    @Test("A batch splits on the semicolons that are separators")
    func splitsOnSeparators() {
        #expect(SQLStatementSplitting.statements(in: "SELECT 1; SELECT 2;") == ["SELECT 1", "SELECT 2"])
        #expect(SQLStatementSplitting.statements(in: "SELECT ';'") == ["SELECT ';'"])
        #expect(SQLStatementSplitting.statements(in: "   ;  ; ").isEmpty)
    }

    @Test("A comment in front of a statement is dropped")
    func leadingCommentsAreDropped() {
        #expect(SQLStatementSplitting.statements(in: "-- note\nSELECT 1") == ["SELECT 1"])
        #expect(SQLStatementSplitting.statements(in: "/* note */ SELECT 1") == ["SELECT 1"])
        #expect(SQLStatementSplitting.statements(in: "# note\nSELECT 1") == ["SELECT 1"])
        #expect(SQLStatementSplitting.statements(in: "/* only a comment */").isEmpty)
    }

    /// `/*!40101 ... */` is SQL, not a comment: MySQL runs the body on any server at or above the
    /// version, MariaDB spells its own `/*M!100301 ... */`, and mysqldump writes its entire
    /// preamble that way. Dropping them as comments left the MySQL driver blind to every `SET` a
    /// restore ran, so it read the session as holding nothing.
    @Test("A version-gated comment is kept, because the server executes it")
    func executableCommentsAreKept() {
        #expect(
            SQLStatementSplitting.statements(in: "/*!40101 SET NAMES utf8 */;")
                == ["/*!40101 SET NAMES utf8 */"]
        )
        #expect(
            SQLStatementSplitting.statements(in: "/*M!100301 SET @x = 1 */;")
                == ["/*M!100301 SET @x = 1 */"]
        )
        #expect(
            SQLStatementSplitting.statements(in: "/*! SET @x = 1 */; SELECT 1")
                == ["/*! SET @x = 1 */", "SELECT 1"]
        )
    }

    /// Keeping it must not make it read as a transaction statement. The keyword is no longer the
    /// first word of the statement, and closing already requires the whole statement to be one.
    @Test("A transaction keyword inside a version-gated comment does not close a transaction")
    func executableCommentsNeverClose() {
        #expect(SQLTransactionTracking.effect(of: "BEGIN; /*!40101 COMMIT */") == .opens)
        #expect(SQLTransactionTracking.effect(of: "/*!40101 COMMIT */") == .unchanged)
    }
}

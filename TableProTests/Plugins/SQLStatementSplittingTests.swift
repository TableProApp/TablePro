//
//  SQLStatementSplittingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("SQL statement splitting")
struct SQLStatementSplittingTests {
    @Test("The engine's own features keep a dollar-quoted body, a nested comment and a bracket whole")
    func featuresKeepEngineLiteralsWhole() {
        #expect(SQLStatementSplitting.statements(in: "SELECT $$a;b$$; SELECT 2", lexicalFeatures: .taggedDollarQuotes)
            == ["SELECT $$a;b$$", "SELECT 2"])
        #expect(SQLStatementSplitting.statements(in: "SELECT $$a;b$$", lexicalFeatures: .untaggedDollarQuotes)
            == ["SELECT $$a;b$$"])
        #expect(SQLStatementSplitting.statements(in: "SELECT $t$a;b$t$", lexicalFeatures: .untaggedDollarQuotes)
            .count == 2)
        #expect(SQLStatementSplitting.statements(in: "SELECT 1 /* /* */ ; */", lexicalFeatures: .nestedBlockComments)
            == ["SELECT 1 /* /* */ ; */"])
        #expect(SQLStatementSplitting.statements(in: "SELECT [a;b]", lexicalFeatures: .bracketQuotedIdentifiers)
            == ["SELECT [a;b]"])
    }

    @Test("A backslash keeps a string open only where the features say so")
    func featuresDecideTheBackslash() {
        #expect(SQLStatementSplitting.statements(in: "SELECT 'a\\'; SELECT 2", lexicalFeatures: []).count == 2)
        #expect(SQLStatementSplitting.statements(
            in: "SELECT 'a\\'; SELECT 2'",
            lexicalFeatures: .backslashEscapesInSingleQuotes
        ).count == 1)
    }

    @Test("Leading comments are read by the engine's own comment rules")
    func featuresStripTheEnginesComments() {
        #expect(SQLStatementSplitting.stripLeadingComments("# a\nSELECT 1", lexicalFeatures: .hashLineComments)
            == "SELECT 1")
        #expect(SQLStatementSplitting.stripLeadingComments("# a\nSELECT 1", lexicalFeatures: []) == "# a\nSELECT 1")
        #expect(SQLStatementSplitting.stripLeadingComments(
            "/*!40101 SET x = 1 */",
            lexicalFeatures: .executableComments
        ) == "/*!40101 SET x = 1 */")
    }

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

    /// Keeping it must not make it read as a transaction statement here. The keyword is no longer
    /// the first word of the statement, and closing already requires the whole statement to be
    /// one. `MySQLSessionFootprint` reads the body itself, because MySQL does run it; every other
    /// caller treats the whole thing as a statement it does not recognise.
    ///
    /// `/*! */ COMMIT` is the case that tells the two implementations apart: stripping the
    /// comment left a bare `COMMIT` and read as `.closes`.
    @Test("A transaction keyword around a version-gated comment does not close a transaction")
    func executableCommentsNeverClose() {
        #expect(SQLTransactionTracking.effect(of: "BEGIN; /*! */ COMMIT") == .opens)
        #expect(SQLTransactionTracking.effect(of: "/*! */ COMMIT") == .unchanged)
        #expect(SQLTransactionTracking.effect(of: "BEGIN; /*!40101 COMMIT */") == .opens)
        #expect(SQLTransactionTracking.effect(of: "/*!40101 COMMIT */") == .unchanged)
    }
}

import Foundation
import Testing

@testable import TablePro

struct StartupStatementsTests {
    @Test("A semicolon or a line break ends a startup statement")
    func separators() {
        let statements = DatabaseManager.startupStatements(
            from: "SET time_zone = '+00:00';\nSET NAMES utf8mb4\nSET autocommit = 1", databaseType: .mysql
        )
        #expect(statements == ["SET time_zone = '+00:00'", "SET NAMES utf8mb4", "SET autocommit = 1"])
    }

    @Test("A semicolon or a line break inside a quote stays in the statement")
    func quotedSeparatorsStay() {
        let statements = DatabaseManager.startupStatements(
            from: "SET @note = 'x;DELETE FROM t;'\nSET search_path TO \"a;b\"", databaseType: .mysql
        )
        #expect(statements == ["SET @note = 'x;DELETE FROM t;'", "SET search_path TO \"a;b\""])
    }

    @Test("A line comment ends at its line, so the statement after it still runs")
    func lineCommentEndsAtItsLine() {
        #expect(DatabaseManager.startupStatements(
            from: "-- setup\nSET application_name = 'TablePro'", databaseType: .postgresql
        ) == ["SET application_name = 'TablePro'"])
        #expect(DatabaseManager.startupStatements(
            from: "# setup; still a comment\nSET NAMES utf8mb4", databaseType: .mysql
        ) == ["SET NAMES utf8mb4"])
    }

    @Test("A Redis startup command never splits a quoted value into another command")
    func redisQuotedValueStays() {
        let statements = DatabaseManager.startupStatements(
            from: "SET marker \"a; FLUSHALL; b\"\nCLIENT SETNAME 'line\nbreak'", databaseType: .redis
        )
        #expect(statements == ["SET marker \"a; FLUSHALL; b\"", "CLIENT SETNAME 'line\nbreak'"])
    }

    @Test("A startup block on a KingbaseES Oracle-mode session runs whole")
    func oracleModeBlockRunsWhole() {
        let block = "BEGIN dbms_session.set_identifier('x'); END;"
        #expect(DatabaseManager.startupStatements(
            from: block, databaseType: .kingbasees, grammar: TestGrammar.kingbaseESOracle
        ) == [block])
    }

    @Test("Blank text holds no startup statement")
    func blank() {
        #expect(DatabaseManager.startupStatements(from: " \n ; ", databaseType: .postgresql).isEmpty)
        #expect(DatabaseManager.startupStatements(from: nil, databaseType: .redis).isEmpty)
    }
}

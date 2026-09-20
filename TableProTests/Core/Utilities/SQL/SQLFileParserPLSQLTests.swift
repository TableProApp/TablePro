//
//  SQLFileParserPLSQLTests.swift
//  TableProTests
//
//  An Oracle script imported from a file reaches the driver the way the same script run in the editor does. The
//  import parser streams the file in 64 KiB chunks, so a word, a quoted literal or a slash line can be cut in two by a
//  chunk boundary, and the split must not depend on where that boundary falls.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

@Suite("SQLFileParser - Oracle PL/SQL units")
struct SQLFileParserPLSQLTests {
    private static let chunkSize = 65_536

    private static func parse(_ sql: String, grammar: SQLLexicalGrammar) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var statements: [String] = []
        for try await (statement, _) in SQLFileParser().parseFile(url: url, encoding: .utf8, grammar: grammar) {
            statements.append(statement)
        }
        return statements
    }

    /// The import parser drops comments, which the editor keeps inside a statement, so the cases compared here are
    /// the ones whose text has none.
    private static let commentFreeCases = PLSQLScriptCorpus.cases.filter { example in
        !example.script.contains("--") && !example.script.contains("/*")
    }

    @Test("An imported script splits like the same script in the editor", arguments: commentFreeCases)
    func importMatchesTheEditor(example: PLSQLScriptCase) async throws {
        #expect(try await Self.parse(example.script, grammar: TestGrammar.oracle) == example.statements)
    }

    @Test("A chunk boundary anywhere in a unit changes nothing")
    func chunkBoundaryAnywhere() async throws {
        let script = """
        DECLARE
          v VARCHAR2(9) := q'[a;b]';
        BEGIN
          $IF TRUE $THEN NULL; $END
        END;
        /
        SELECT 1 FROM dual;
        """
        let expected = [
            "DECLARE\n  v VARCHAR2(9) := q'[a;b]';\nBEGIN\n  $IF TRUE $THEN NULL; $END\nEND;",
            "SELECT 1 FROM dual",
        ]
        for boundary in 0..<(script as NSString).length {
            let padding = "--" + String(repeating: "x", count: Self.chunkSize - boundary - 3) + "\n"
            let statements = try await Self.parse(padding + script, grammar: TestGrammar.oracle)
            #expect(statements == expected, "boundary at \(boundary)")
        }
    }

    @Test("A slash line at the end of the file ends the statement before it")
    func slashLineAtEndOfFile() async throws {
        #expect(try await Self.parse("SELECT 1 FROM dual\n/", grammar: TestGrammar.oracle) == ["SELECT 1 FROM dual"])
    }

    @Test("A slash that shares its line with code is division")
    func slashWithCodeIsDivision() async throws {
        #expect(try await Self.parse("SELECT 4\n/ 2 AS v FROM dual;", grammar: TestGrammar.oracle) == ["SELECT 4\n/ 2 AS v FROM dual"])
    }

    @Test("Other dialects still split an import at every semicolon", arguments: [
        TestGrammar.mysql, TestGrammar.postgres, TestGrammar.standard
    ])
    func otherDialectsAreUnchanged(grammar: SQLLexicalGrammar) async throws {
        let statements = try await Self.parse("BEGIN NULL; END;", grammar: grammar)
        #expect(statements == ["BEGIN NULL", "END"])
    }

    /// The parser holds a character back while it waits for the one after it, and the end of the file used to leave
    /// it held: a file ending `ORDER BY created_on` imported as `created_o`.
    @Test("A file's last character survives when nothing follows it")
    func lastCharacterSurvives() async throws {
        let cases: [(grammar: SQLLexicalGrammar, sql: String)] = [
            (TestGrammar.oracle, "SELECT a FROM t ORDER BY created_on"),
            (TestGrammar.oracle, "SELECT q FROM t"),
            (TestGrammar.standard, "SELECT 'abc'"),
            (TestGrammar.mysql, "SELECT 1 - 1"),
        ]
        for example in cases {
            #expect(try await Self.parse(example.sql, grammar: example.grammar) == [example.sql], "\(example.sql)")
        }
    }
}

import Foundation
import TableProSQLGrammar
import Testing

struct CursorIndexFixture: Sendable, CustomStringConvertible {
    let typeId: String
    let text: String

    var description: String {
        typeId
    }
}

private let cursorIndexFixtures = [
    CursorIndexFixture(typeId: "PostgreSQL", text: """
    SELECT 1;

    -- a note; with a semicolon
    SELECT 'a;b';
    CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql;
    /* c; */ SELECT E'x'
    'y';;
    SELECT 2
    """),
    CursorIndexFixture(typeId: "MySQL", text: """
    CREATE PROCEDURE p()
    BEGIN
      SELECT 1;
      SELECT 2;
    END;
    SELECT 3;;
    # hash; comment
    SELECT `a;b` FROM t;
    SELECT /*! 1; */ 2
    """),
    CursorIndexFixture(typeId: "SQL Server", text: """
    SELECT 1
    GO
    SELECT 2;
    GO 3
    MERGE t USING s ON 1 = 1 WHEN MATCHED THEN DELETE;
    GO

    GO
    SELECT [a;b]
    GO
    """),
    CursorIndexFixture(typeId: "Oracle", text: """
    BEGIN
      NULL;
    END;
    /
    SELECT 1 FROM dual
    /
    SELECT q'[a;b]' FROM dual;
    /
    CREATE OR REPLACE PROCEDURE p IS
    BEGIN
      NULL;
    END;
    /
    """),
    CursorIndexFixture(typeId: "Cassandra", text: """
    BEGIN BATCH
    INSERT INTO t (a) VALUES (1);
    INSERT INTO t (a) VALUES (2);
    APPLY BATCH;
    SELECT * FROM t;
    """),
]

private let cursorIndexInsertions = [
    ";", "'", "\nGO\n", "\n/\n", " ", "x", "$$", "BEGIN ", "END;", "--", "/*", "*/", "\n", "GO", "/",
]

private let longScriptRow = "SELECT id, name FROM users WHERE active = true;\n"

struct SQLStatementCursorIndexTests {
    private static func grammar(_ typeId: String) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
    }

    private struct Resolved: Equatable, CustomStringConvertible {
        let offset: Int
        let sql: String
        let hasContent: Bool
        let terminator: SQLStatementTerminator
        let acceptsBindParameters: Bool
        let contentRange: NSRange

        init(_ statement: SQLStatementScanner.LocatedStatement) {
            offset = statement.offset
            sql = statement.sql
            hasContent = statement.hasContent
            terminator = statement.terminator
            acceptsBindParameters = statement.acceptsBindParameters
            contentRange = statement.contentRange
        }

        var description: String {
            "\(offset) \(hasContent) \(sql.debugDescription)"
        }
    }

    private static func fresh(_ text: String, _ cursor: Int, _ grammar: SQLLexicalGrammar) -> Resolved {
        Resolved(SQLStatementScanner.locatedStatementAtCursor(in: text, cursorPosition: cursor, grammar: grammar))
    }

    @Test("Every caret resolves to what a scan from the top resolves to", arguments: cursorIndexFixtures)
    func everyCaretMatchesAFreshScan(_ fixture: CursorIndexFixture) {
        let grammar = Self.grammar(fixture.typeId)
        let text = fixture.text
        let length = (text as NSString).length
        var index = SQLStatementCursorIndex(grammar: grammar, checkpointSpacing: 1)
        var generator = SplitMix64(seed: 7)
        let shuffled = Array(0...length).shuffled(using: &generator)

        for cursor in Array(0...length) + Array((0...length).reversed()) + shuffled {
            #expect(Resolved(index.statementAtCursor(cursor, in: text)) == Self.fresh(text, cursor, grammar), "caret \(cursor)")
        }
        #expect(index.checkpointCount > 0)
    }

    @Test("After any edit every caret still resolves to what a fresh scan resolves to", arguments: cursorIndexFixtures)
    func editsKeepEveryAnswer(_ fixture: CursorIndexFixture) {
        let grammar = Self.grammar(fixture.typeId)
        var text = fixture.text
        var index = SQLStatementCursorIndex(grammar: grammar, checkpointSpacing: 1)
        var generator = SplitMix64(seed: 42)

        for step in 0..<80 {
            let length = (text as NSString).length
            for cursor in Array(0...length).shuffled(using: &generator).prefix(24) {
                _ = index.statementAtCursor(cursor, in: text)
            }

            let mutable = NSMutableString(string: text)
            if length > 0, Bool.random(using: &generator) {
                let start = Int.random(in: 0..<length, using: &generator)
                let removed = min(Int.random(in: 1...4, using: &generator), length - start)
                mutable.deleteCharacters(in: NSRange(location: start, length: removed))
                index.textDidChange(at: start)
            } else {
                let location = Int.random(in: 0...length, using: &generator)
                mutable.insert(cursorIndexInsertions.randomElement(using: &generator) ?? ";", at: location)
                index.textDidChange(at: location)
            }
            text = mutable as String

            for cursor in 0...(text as NSString).length {
                #expect(
                    Resolved(index.statementAtCursor(cursor, in: text)) == Self.fresh(text, cursor, grammar),
                    "step \(step) caret \(cursor)"
                )
            }
        }
    }

    @Test("A boundary survives an edit after its semicolon and goes with an edit on it")
    func semicolonBoundaryDependsOnlyOnTheTextBeforeIt() {
        let text = "SELECT 1;SELECT 2;SELECT 3;"
        var index = SQLStatementCursorIndex(grammar: .ansi, checkpointSpacing: 1)
        _ = index.statementAtCursor((text as NSString).length, in: text)
        #expect(index.checkpointCount == 2)

        index.textDidChange(at: 18)
        #expect(index.checkpointCount == 2)

        index.textDidChange(at: 17)
        #expect(index.checkpointCount == 1)
    }

    @Test("Text typed after a GO line at the end of a line can unmake it")
    func goLineBoundaryDependsOnItsLineBreak() {
        let grammar = Self.grammar("SQL Server")
        var text = "SELECT 1\nGO\nSELECT 2"
        var index = SQLStatementCursorIndex(grammar: grammar, checkpointSpacing: 1)
        #expect(index.statementAtCursor((text as NSString).length, in: text).offset == 11)

        text = "SELECT 1\nGOx\nSELECT 2"
        index.textDidChange(at: 11)
        let after = index.statementAtCursor((text as NSString).length, in: text)
        #expect(Resolved(after) == Self.fresh(text, (text as NSString).length, grammar))
        #expect(after.offset == 0)
    }

    @Test("Text typed after a slash line can unmake it")
    func slashLineBoundaryDependsOnTheRestOfItsLine() {
        let grammar = Self.grammar("Oracle")
        var text = "SELECT 1 FROM dual\n/\nSELECT 2 FROM dual"
        var index = SQLStatementCursorIndex(grammar: grammar, checkpointSpacing: 1)
        #expect(index.statementAtCursor((text as NSString).length, in: text).offset == 20)

        text = "SELECT 1 FROM dual\n/ x\nSELECT 2 FROM dual"
        index.textDidChange(at: 20)
        let after = index.statementAtCursor((text as NSString).length, in: text)
        #expect(Resolved(after) == Self.fresh(text, (text as NSString).length, grammar))
        #expect(after.offset == 0)
    }

    // 10,000 rows of 48 units: a scan from the top walks about 480,000 units per caret move.
    @Test("Moving the caret near the end of a long script rescans only near the caret")
    func caretMovesScanOnlyNearTheCaret() {
        let grammar = Self.grammar("PostgreSQL")
        let text = String(repeating: longScriptRow, count: 10_000)
        let length = (text as NSString).length
        let rowLength = (longScriptRow as NSString).length
        var index = SQLStatementCursorIndex(grammar: grammar)

        _ = index.statementAtCursor(length - 10, in: text)
        let warmed = index.unitsScanned
        #expect(warmed >= length - 2 * rowLength)

        let moves = 1_000
        for step in 0..<moves {
            let cursor = length - 10 - step
            let found = index.statementAtCursor(cursor, in: text)
            if step.isMultiple(of: 250) {
                #expect(Resolved(found) == Self.fresh(text, cursor, grammar), "move \(step)")
            }
        }
        let bound = moves * (SQLStatementCursorIndex.defaultCheckpointSpacing + 2 * rowLength)
        #expect(index.unitsScanned - warmed <= bound)
    }

    @Test("Typing near the end of a long script rescans from the last boundary before the edit")
    func typingScansOnlyFromTheBoundaryBeforeTheEdit() {
        let grammar = Self.grammar("PostgreSQL")
        var text = String(repeating: longScriptRow, count: 10_000)
        let rowLength = (longScriptRow as NSString).length
        var index = SQLStatementCursorIndex(grammar: grammar)
        _ = index.statementAtCursor((text as NSString).length, in: text)
        let warmed = index.unitsScanned

        var caret = (text as NSString).length - 20
        let keystrokes = 200
        for _ in 0..<keystrokes {
            let mutable = NSMutableString(string: text)
            mutable.insert("x", at: caret)
            text = mutable as String
            index.textDidChange(at: caret)
            caret += 1
            _ = index.statementAtCursor(caret, in: text)
        }

        #expect(Resolved(index.statementAtCursor(caret, in: text)) == Self.fresh(text, caret, grammar))
        let typedRow = rowLength + keystrokes
        let bound = (keystrokes + 1) * (SQLStatementCursorIndex.defaultCheckpointSpacing + 2 * typedRow)
        #expect(index.unitsScanned - warmed <= bound)
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

import Foundation
import TableProSQLGrammar
import Testing

// T-SQL reserves BEGIN, so a BEGIN ... END block holds its `;`s wherever it stands, not only in a routine's body.
struct TSQLControlFlowBlockTests {
    private static let sqlServer = SQLLexicalReadings.resolve(databaseTypeId: "SQL Server", declared: nil, session: nil)
        .execution

    private static let merge = "MERGE dbo.t AS t USING dbo.s AS s ON t.id = s.id WHEN MATCHED THEN DELETE"

    private func sent(_ sql: String) -> [String] {
        SQLStatementScanner.executableStatements(in: sql, grammar: Self.sqlServer).map(\.sql)
    }

    private func atCursor(_ sql: String, on marker: String) -> String {
        let offset = (sql as NSString).range(of: marker).location
        return SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: offset, grammar: Self.sqlServer)
    }

    @Test("A block an IF, a WHILE or a statement of its own opens stays one statement", arguments: [
        ("IF 1=1 BEGIN SELECT 1; SELECT 2; END; SELECT 3", ["IF 1=1 BEGIN SELECT 1; SELECT 2; END", "SELECT 3"]),
        (
            "WHILE @i < 3\nBEGIN\n  SET @i += 1;\n  PRINT @i;\nEND;\nSELECT @i;",
            ["WHILE @i < 3\nBEGIN\n  SET @i += 1;\n  PRINT @i;\nEND", "SELECT @i"]
        ),
        ("BEGIN\n  SELECT 1;\n  SELECT 2;\nEND;\nSELECT 3;", ["BEGIN\n  SELECT 1;\n  SELECT 2;\nEND", "SELECT 3"]),
        (
            "IF @a = 1 BEGIN IF @b = 1 BEGIN SELECT 1; END ELSE BEGIN SELECT 2; END; SELECT 3; END; SELECT 4",
            ["IF @a = 1 BEGIN IF @b = 1 BEGIN SELECT 1; END ELSE BEGIN SELECT 2; END; SELECT 3; END", "SELECT 4"]
        ),
        (
            "BEGIN TRY\n  DELETE FROM a;\nEND TRY\nBEGIN CATCH\n  SELECT ERROR_MESSAGE();\nEND CATCH;\nSELECT 9;",
            ["BEGIN TRY\n  DELETE FROM a;\nEND TRY\nBEGIN CATCH\n  SELECT ERROR_MESSAGE();\nEND CATCH", "SELECT 9"]
        ),
    ])
    func blockHoldsItsSemicolons(sql: String, expected: [String]) {
        #expect(sent(sql) == expected)
    }

    @Test("Run Current anywhere in a conditional block runs the whole block")
    func caretInsideTheBlockRunsTheBlock() {
        let block = "IF @env = 'dev'\nBEGIN\n  DELETE FROM a;\n  DELETE FROM b;\nEND"
        let sql = "SELECT 0;\n\(block);\nSELECT 9;"

        #expect(atCursor(sql, on: "IF @env") == block)
        #expect(atCursor(sql, on: "DELETE FROM b") == block)
        #expect(SQLStatementScanner.navigableStatements(in: sql, grammar: Self.sqlServer).count == 3)
    }

    @Test("An END is never followed by more of its block, so the IF after it is the next statement")
    func endBeforeTheNextStatementClosesTheBlock() {
        let sql = "IF @a = 1 BEGIN SELECT 1; END\nIF @b = 1 BEGIN SELECT 2; END;\nSELECT 3;"

        #expect(sent(sql) == ["IF @a = 1 BEGIN SELECT 1; END\nIF @b = 1 BEGIN SELECT 2; END", "SELECT 3"])
        #expect(!SQLStatementScanner.endsInsideOpenBlock(sql, grammar: Self.sqlServer))
    }

    @Test("A transaction's BEGIN is a statement, not a block", arguments: ["TRAN", "TRANSACTION", "DISTRIBUTED TRANSACTION"])
    func transactionBeginIsAStatement(opener: String) {
        #expect(sent("BEGIN \(opener);\nUPDATE t SET a = 1;\nCOMMIT;") == ["BEGIN \(opener)", "UPDATE t SET a = 1", "COMMIT"])
    }

    @Test("Service Broker's BEGIN DIALOG, BEGIN CONVERSATION TIMER and END CONVERSATION are statements")
    func serviceBrokerStatementsAreNotBlocks() {
        let script = """
        BEGIN DIALOG CONVERSATION @h FROM SERVICE [s] TO SERVICE 't' ON CONTRACT [c];
        BEGIN CONVERSATION TIMER (@h) TIMEOUT = 60;
        END CONVERSATION @h;
        SELECT 1;
        """
        #expect(sent(script).count == 4)

        let inBlock = "IF @x = 1 BEGIN END CONVERSATION @h; SELECT 1; END; SELECT 2"
        #expect(sent(inBlock) == ["IF @x = 1 BEGIN END CONVERSATION @h; SELECT 1; END", "SELECT 2"])
    }

    @Test("A CASE expression closes at its own END, and one left open at a ; does not hold the next statement")
    func caseExpressions() {
        #expect(sent("SELECT CASE WHEN a = 1 THEN 'x' END AS c FROM t;\nSELECT 2;").count == 2)
        #expect(sent("IF @x = 1 BEGIN SELECT CASE WHEN @x = 1 THEN 1 END; SELECT 2; END; SELECT 3").count == 2)
        #expect(sent("SELECT CASE WHEN a = 1 THEN 1;\nSELECT 2;") == ["SELECT CASE WHEN a = 1 THEN 1", "SELECT 2"])
    }

    @Test("A MERGE inside a block keeps its ; and the block's own ; is a separator")
    func mergeInsideABlock() {
        let block = "IF 1 = 1 BEGIN \(Self.merge); END"
        #expect(sent(block + ";\nSELECT 1;") == [block, "SELECT 1"])
    }

    @Test("A block left open runs to its GO line and no further")
    func goLineEndsAnOpenBlock() {
        let sql = "IF 1 = 1 BEGIN SELECT 1;\nGO\nSELECT 2"
        #expect(sent(sql) == ["IF 1 = 1 BEGIN SELECT 1", "SELECT 2"])
        #expect(SQLStatementScanner.endsInsideOpenBlock("IF 1 = 1 BEGIN SELECT 1;", grammar: Self.sqlServer))
    }

    @Test("The gate still tiers every statement a block holds")
    func gateTiersEachStatementInsideTheBlock() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "SQL Server", declared: nil, session: nil)
        let sql = "IF @env = 'dev' BEGIN SELECT 1; DROP TABLE dbo.t; END"

        #expect(SQLStatementClassifier.classify(sql, databaseTypeId: "SQL Server", readings: readings).tier == .destructive)
        #expect(SQLStatementClassifier.deletesEveryRow(
            "IF 1 = 1 BEGIN DELETE FROM dbo.t; END", databaseTypeId: "SQL Server", readings: readings
        ))
    }

    @Test("A TRY block after a statement written without a ; is still one block")
    func tryBlockAfterAnUnterminatedStatement() {
        let script = "SET XACT_ABORT ON\nBEGIN TRY\n  DELETE FROM a;\nEND TRY\nBEGIN CATCH\n  THROW;\nEND CATCH;\nSELECT 1;"
        #expect(sent(script).count == 2)
        #expect(sent(script).last == "SELECT 1")
    }

    @Test("A begin where a name stands opens no block", arguments: [
        ("CREATE TABLE begin(a int); DROP TABLE users", 2),
        ("INSERT INTO begin VALUES (1); DROP TABLE users", 2),
        ("DO BEGIN SELECT 1 FROM DUMMY; SELECT 2 FROM DUMMY; END;", 3),
    ])
    func nameInBeginsPlaceOpensNothing(sql: String, count: Int) {
        #expect(sent(sql).count == count)
    }

    @Test("A block holding more than one statement is told apart from one statement", arguments: [
        ("IF x BEGIN UPDATE a SET c = 1; UPDATE b SET c = 1; END", true),
        ("BEGIN MERGE dbo.t AS t USING dbo.s AS s ON t.id = s.id WHEN MATCHED THEN DELETE; SELECT 1; END", true),
        ("IF x BEGIN SELECT 1; WITH c AS (SELECT id FROM t) DELETE FROM c; END", true),
        ("IF x BEGIN SELECT 1; DISABLE TRIGGER trg ON t; END", true),
        ("BEGIN TRY SELECT 1; THROW 50000, 'x', 1; END TRY BEGIN CATCH SELECT 2; END CATCH", true),
        ("IF x BEGIN SELECT 1; done: SELECT 2; END", true),
        ("IF x BEGIN SELECT 1; (SELECT 2); END", true),
        ("IF x BEGIN SELECT 1; END CONVERSATION @h; END", true),
        ("IF x SELECT 1", false),
        ("IF x BEGIN SELECT 1; END", false),
        ("IF x BEGIN SELECT 1;; END", false),
        ("BEGIN IF x SELECT 1; ELSE SELECT 2; END", false),
        ("BEGIN TRY SELECT 1; END TRY BEGIN CATCH THROW; END CATCH", false),
        ("CREATE PROCEDURE p AS BEGIN SELECT 1; SELECT 2; END", false),
    ])
    func blockHoldingSeveralStatements(sql: String, holdsSeveral: Bool) {
        #expect(SQLUnterminatedStatements.blockHoldsSeveralStatements(sql, grammar: Self.sqlServer) == holdsSeveral)
        let postgreSQL = SQLLexicalReadings.resolve(databaseTypeId: "PostgreSQL", declared: nil, session: nil).execution
        #expect(!SQLUnterminatedStatements.blockHoldsSeveralStatements(sql, grammar: postgreSQL))
    }

    @Test("A ; that ends an IF's body before its ELSE stays inside the IF", arguments: [
        (
            "IF DATENAME(weekday, GETDATE()) IN (N'Saturday', N'Sunday')\n       SELECT 'Weekend';\nELSE\n       SELECT 'Weekday';",
            ["IF DATENAME(weekday, GETDATE()) IN (N'Saturday', N'Sunday')\n       SELECT 'Weekend';\nELSE\n       SELECT 'Weekday'"]
        ),
        ("IF @a = 1 SELECT 1; -- one\nELSE SELECT 2; SELECT 3", ["IF @a = 1 SELECT 1; -- one\nELSE SELECT 2", "SELECT 3"]),
        (
            "IF @a = 1 IF @b = 1 SELECT 1; ELSE SELECT 2; ELSE SELECT 3; SELECT 4",
            ["IF @a = 1 IF @b = 1 SELECT 1; ELSE SELECT 2; ELSE SELECT 3", "SELECT 4"]
        ),
        (
            "IF @a = 1 SELECT 1; ELSE IF @b = 1 SELECT 2; ELSE SELECT 3; SELECT 4",
            ["IF @a = 1 SELECT 1; ELSE IF @b = 1 SELECT 2; ELSE SELECT 3", "SELECT 4"]
        ),
        ("WHILE @i < 3 IF @i = 1 BREAK; ELSE SET @i += 1; SELECT @i", ["WHILE @i < 3 IF @i = 1 BREAK; ELSE SET @i += 1", "SELECT @i"]),
        ("IF @a = 1 BEGIN SELECT 1; END; ELSE SELECT 2; SELECT 3", ["IF @a = 1 BEGIN SELECT 1; END; ELSE SELECT 2", "SELECT 3"]),
        ("IF @a = 1 SELECT 1;; ELSE SELECT 2", ["IF @a = 1 SELECT 1;; ELSE SELECT 2"]),
        ("IF @a = 1 \(Self.merge); ELSE SELECT 2;", ["IF @a = 1 \(Self.merge); ELSE SELECT 2"]),
        ("IF @a = 1 SELECT 1; ELSE \(Self.merge);", ["IF @a = 1 SELECT 1; ELSE \(Self.merge);"]),
    ])
    func semicolonBeforeElse(sql: String, expected: [String]) {
        #expect(sent(sql) == expected)
        #expect(!SQLUnterminatedStatements.blockHoldsSeveralStatements(expected[0], grammar: Self.sqlServer))
    }

    @Test("A ; after an IF's body ends the IF when no ELSE follows", arguments: [
        ("IF @a = 1 SELECT 1; SELECT 2;", ["IF @a = 1 SELECT 1", "SELECT 2"]),
        ("IF @a = 1 SELECT 1;\n", ["IF @a = 1 SELECT 1"]),
        ("IF @a = 1 SELECT 1;; SELECT 2", ["IF @a = 1 SELECT 1", "SELECT 2"]),
        ("IF @a = 1 SELECT 1; [ELSE]", ["IF @a = 1 SELECT 1", "[ELSE]"]),
        ("IF @a = 1 SELECT 1; ELSEWHERE", ["IF @a = 1 SELECT 1", "ELSEWHERE"]),
        ("IF @a = 1 SELECT 1 ELSE SELECT 2; ELSE SELECT 3", ["IF @a = 1 SELECT 1 ELSE SELECT 2", "ELSE SELECT 3"]),
        ("SELECT 1; ELSE SELECT 2", ["SELECT 1", "ELSE SELECT 2"]),
        ("DROP TABLE IF EXISTS t; SELECT 1", ["DROP TABLE IF EXISTS t", "SELECT 1"]),
        (
            "IF @a = 1 SELECT CASE WHEN @b = 1 THEN 1 ELSE 2 END; SELECT 3",
            ["IF @a = 1 SELECT CASE WHEN @b = 1 THEN 1 ELSE 2 END", "SELECT 3"]
        ),
    ])
    func semicolonWithoutElse(sql: String, expected: [String]) {
        #expect(sent(sql) == expected)
    }

    @Test("Run Current anywhere in an IF ... ELSE runs the whole IF, and the gate tiers both branches")
    func caretOnTheElseRunsTheIf() {
        let statement = "IF @env = 'dev'\n  SELECT 1;\nELSE\n  DROP TABLE dbo.t"
        let sql = "SELECT 0;\n\(statement);\nSELECT 9;"

        #expect(atCursor(sql, on: "ELSE") == statement)
        #expect(atCursor(sql, on: "DROP") == statement)
        #expect(atCursor(sql, on: "SELECT 9") == "SELECT 9")
        #expect(SQLStatementScanner.navigableStatements(in: sql, grammar: Self.sqlServer).count == 3)

        let readings = SQLLexicalReadings.resolve(databaseTypeId: "SQL Server", declared: nil, session: nil)
        #expect(SQLStatementClassifier.classify(statement, databaseTypeId: "SQL Server", readings: readings).tier == .destructive)
    }

    @Test("Other engines still read BEGIN outside a routine as a word", arguments: ["PostgreSQL", "MySQL", "SQLite"])
    func otherEnginesAreUnchanged(typeId: String) {
        let grammar = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
        let statements = SQLStatementScanner.executableStatements(in: "BEGIN\nDELETE FROM t;\nSELECT 1;", grammar: grammar)
        #expect(statements.map { $0.sql } == ["BEGIN\nDELETE FROM t", "SELECT 1"])
    }
}

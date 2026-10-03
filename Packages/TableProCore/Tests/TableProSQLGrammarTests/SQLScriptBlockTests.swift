import Foundation
import TableProSQLGrammar
import Testing

@Suite("SAP HANA SQLScript blocks")
struct SQLScriptBlockTests {
    private static let hana = SQLLexicalReadings.resolve(databaseTypeId: "SAP HANA", declared: nil, session: nil)
        .execution

    private func sent(_ sql: String, _ grammar: SQLLexicalGrammar = hana) -> [String] {
        SQLStatementScanner.executableStatements(in: sql, grammar: grammar).map(\.sql)
    }

    @Test("SAP HANA splits with its own grammar")
    func hanaIsCurated() {
        #expect(Self.hana == [.dollarAndHashInIdentifiers, .sqlScriptBlocks])
    }

    @Test("A DO block and the selects inside it are one statement")
    func doBlockWithInnerSelectsIsOneStatement() {
        let block = "DO BEGIN\n    SELECT 1 FROM DUMMY;\n    SELECT 2 FROM DUMMY;\nEND"

        #expect(sent(block + ";\nSELECT 3 FROM DUMMY;") == [block, "SELECT 3 FROM DUMMY"])
    }

    @Test("Nested blocks, control flow and a handler stay inside the DO block")
    func nestedBlocksStayInside() {
        let block = """
            DO BEGIN
                DECLARE total INT = 0;
                DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN
                    SELECT ::SQL_ERROR_CODE FROM DUMMY;
                END;
                BEGIN
                    SELECT COUNT(*) INTO total FROM DUMMY;
                END;
                IF :total > 0 THEN
                    SELECT 'some' FROM DUMMY;
                ELSE
                    SELECT 'none' FROM DUMMY;
                END IF;
                FOR i IN 1..3 DO
                    SELECT :i FROM DUMMY;
                END FOR;
                WHILE :total < 3 DO
                    total = :total + 1;
                END WHILE;
                SELECT CASE WHEN :total = 3 THEN 'done' END FROM DUMMY;
            END
            """

        #expect(sent(block + ";\nSELECT 4 FROM DUMMY;") == [block, "SELECT 4 FROM DUMMY"])
    }

    @Test("A DO block with a parameter clause is one statement")
    func doBlockWithParametersIsOneStatement() {
        let block = "DO (IN a INT => 1, OUT b TABLE (x INT) => ?) BEGIN b = SELECT :a AS x FROM DUMMY; END"

        #expect(sent(block + ";") == [block])
    }

    @Test("A stored procedure and a function keep their bodies whole")
    func routineDefinitionsStayWhole() {
        let procedure = "CREATE PROCEDURE app.refresh (IN n INT) AS BEGIN SELECT :n FROM DUMMY; SELECT 1 FROM t; END"
        let function = "CREATE FUNCTION app.twice (x INT) RETURNS y INT AS BEGIN y = :x * 2; END"
        let script = "\(procedure);\n\(function);\nSELECT 1 FROM DUMMY;"

        #expect(sent(script) == [procedure, function, "SELECT 1 FROM DUMMY"])
    }

    @Test("A $ or # inside a name keeps a keyword-like tail from closing the block")
    func dollarAndHashContinueANameInsideABlock() {
        let block = "DO BEGIN SELECT A#END, B$END FROM DUMMY; SELECT 2 FROM DUMMY; END"

        #expect(sent(block + ";") == [block])
        #expect(sent(block + ";", [.sqlScriptBlocks]).count > 1)
    }

    @Test("A local temporary table name is not a comment")
    func localTemporaryTablesSplitAsStatements() {
        let script = "CREATE LOCAL TEMPORARY TABLE #rows (a INT);\nINSERT INTO #rows VALUES (1);\nSELECT * FROM #rows;"

        #expect(sent(script) == [
            "CREATE LOCAL TEMPORARY TABLE #rows (a INT)", "INSERT INTO #rows VALUES (1)", "SELECT * FROM #rows"
        ])
    }

    @Test("Two plain statements still split")
    func plainStatementsStillSplit() {
        #expect(sent("SELECT 1 FROM DUMMY; SELECT 2 FROM DUMMY") == ["SELECT 1 FROM DUMMY", "SELECT 2 FROM DUMMY"])
    }

    @Test("A :name inside a block reads a variable, and outside one a bind parameter")
    func bindParametersOnlyOutsideABlock() {
        let script = """
            DO BEGIN SELECT :a FROM DUMMY; END;
            CREATE PROCEDURE p (IN a INT) AS BEGIN SELECT :a FROM DUMMY; END;
            SELECT * FROM t WHERE id = :id;
            """
        let statements = SQLStatementScanner.executableStatements(in: script, grammar: Self.hana)

        #expect(statements.map(\.acceptsBindParameters) == [false, false, true])
    }

    @Test("SAP HANA is the only curated engine that reads SQLScript blocks")
    func onlyHanaReadsSQLScriptBlocks() {
        let reading = SQLLexicalProfile.curatedDatabaseTypeIds.filter { typeId in
            SQLLexicalProfile.curated(forDatabaseTypeId: typeId)?.readings.contains {
                $0.contains(.sqlScriptBlocks)
            } == true
        }

        #expect(reading == ["SAP HANA"])
        #expect(SQLLexicalProfile.everyKnownReading.allSatisfy { !$0.contains(.sqlScriptBlocks) })
    }

    @Test(
        "Other engines split a DO block and bind a routine's :name as they always have",
        arguments: ["PostgreSQL", "MySQL", "SQL Server", "Oracle", "Dameng", "Teradata", "Nonesuch"]
    )
    func otherEnginesAreUnchanged(typeId: String) {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil)
        let doBlock = "DO BEGIN SELECT 1 FROM DUMMY; SELECT 2 FROM DUMMY; END;"
        let procedure = "CREATE PROCEDURE p () BEGIN SELECT :a FROM DUMMY; END;"

        for grammar in readings.all {
            #expect(sent(doBlock, grammar).count == 3, "\(typeId)")
        }
        guard !readings.execution.contains(.plsqlBlocks) else { return }
        let located = SQLStatementScanner.executableStatements(in: procedure, grammar: readings.execution)
        #expect(located.map(\.acceptsBindParameters) == [true], "\(typeId)")
    }
}

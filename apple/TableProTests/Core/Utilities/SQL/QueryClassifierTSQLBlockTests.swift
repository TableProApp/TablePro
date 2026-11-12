import Foundation
@testable import TablePro
import TableProSQLGrammar
import Testing

// A T-SQL block runs as one statement, and a caller allowed one statement at a time is still refused one holding more.
struct QueryClassifierTSQLBlockTests {
    @Test("A block holding more than one statement is multi-statement", arguments: [
        "IF @x = 1 BEGIN UPDATE a SET c = 1; UPDATE b SET c = 1; END",
        "BEGIN TRY DELETE FROM a WHERE id = 1; DELETE FROM b WHERE id = 1; END TRY BEGIN CATCH SELECT 1; END CATCH",
        "WHILE @i < 3 BEGIN SET @i += 1; PRINT @i; END",
        "IF @x = 1 BEGIN SELECT 1; WITH c AS (SELECT id FROM t) DELETE FROM c; END",
        "IF @x = 1 BEGIN SELECT 1; DISABLE TRIGGER trg ON t; END",
        "BEGIN TRY SELECT 1; THROW 50000, 'x', 1; END TRY BEGIN CATCH SELECT 2; END CATCH",
        "IF @x = 1 BEGIN SELECT 1; done: SELECT 2; END",
        "IF @x = 1 BEGIN SELECT 1; (SELECT 2); END",
    ])
    func blockOfSeveralIsMulti(sql: String) {
        #expect(QueryClassifier.isMultiStatement(sql, databaseType: .mssql))
    }

    @Test("A conditional statement, or a block holding one, is a single statement", arguments: [
        "IF @x = 1 SELECT 1",
        "IF @x = 1 BEGIN SELECT 1; END",
        "BEGIN SELECT 1 END",
        "BEGIN IF @x = 1 SELECT 1; ELSE SELECT 2; END",
        "BEGIN TRY SELECT 1; END TRY BEGIN CATCH THROW; END CATCH",
    ])
    func singleStatementIsNotMulti(sql: String) {
        #expect(!QueryClassifier.isMultiStatement(sql, databaseType: .mssql))
    }

    @Test("A stored routine's body runs nothing, so it is one statement however many it holds")
    func routineBodyIsNotMulti() {
        #expect(!QueryClassifier.isMultiStatement(
            "CREATE PROCEDURE dbo.p AS BEGIN UPDATE a SET c = 1; UPDATE b SET c = 1; END", databaseType: .mssql
        ))
    }
}

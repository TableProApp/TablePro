import Foundation
@testable import TablePro
import TableProSQLGrammar
import Testing

// A script line the client reads, a DELIMITER or a COPY's rows, never lets a second statement past the gate.
struct QueryClassifierClientScriptTests {
    @Test("A routine between DELIMITER lines is one statement for the gate")
    func delimitedRoutineIsOneStatement() {
        let sql = "DELIMITER //\nCREATE PROCEDURE p() BEGIN UPDATE a SET c = 1; UPDATE b SET c = 1; END//\nDELIMITER ;"
        #expect(!QueryClassifier.isMultiStatement(sql, databaseType: .mysql))
    }

    @Test("A ; the server splits at is still a second statement under a custom delimiter")
    func customDelimiterHidesNoStatement() {
        let sql = "DELIMITER //\nSELECT 1; DROP TABLE users//"
        #expect(QueryClassifier.isMultiStatement(sql, databaseType: .mysql))
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: .mysql))
    }

    @Test("A COPY's rows are never statements, and the COPY is never safe")
    func copyRowsAreNotStatements() {
        let sql = "COPY t FROM stdin;\nx\tDROP TABLE users;\n\\.\n"
        #expect(!QueryClassifier.isMultiStatement(sql, databaseType: .postgresql))
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) != .safe)
        #expect(QueryClassifier.isMultiStatement(sql + "SELECT 1;", databaseType: .postgresql))
    }

    @Test("An IF ... ELSE with a ; before the ELSE is one statement, and both branches are tiered")
    func ifElseIsOneStatement() {
        let sql = "IF @env = 'dev' SELECT 1; ELSE DROP TABLE dbo.t;"
        #expect(!QueryClassifier.isMultiStatement(sql, databaseType: .mssql))
        #expect(QueryClassifier.classifyTier(sql, databaseType: .mssql) == .destructive)
    }
}

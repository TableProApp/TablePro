import Foundation
@testable import TablePro
import Testing

struct QueryClassifierSQLScriptTests {
    @Test("A DO block is one statement that runs server-side code and is at least a write")
    func doBlockIsOneCodeExecution() {
        let sql = "DO BEGIN\n    SELECT 1 FROM DUMMY;\n    SELECT 2 FROM DUMMY;\nEND;"
        let classification = QueryClassifier.classify(sql, databaseType: .sapHana)

        #expect(classification.tier == .write)
        #expect(classification.reachesFilesystemOrExecutesCode)
        #expect(!QueryClassifier.isMultiStatement(sql, databaseType: .sapHana))
    }

    @Test("Two plain statements are still two")
    func plainStatementsStayMultiple() {
        #expect(QueryClassifier.isMultiStatement("SELECT 1 FROM DUMMY; SELECT 2 FROM DUMMY", databaseType: .sapHana))
    }

    @Test("A drop the DO block spells out is destructive", arguments: [
        "DO BEGIN DROP TABLE users; END;",
        "DO BEGIN SELECT 1 FROM DUMMY; BEGIN TRUNCATE TABLE users; END; END;",
        "DO BEGIN EXECUTE IMMEDIATE 'DROP TABLE users'; END;",
        "DO BEGIN EXEC 'DROP TABLE users'; END;"
    ])
    func dropInsideABlockIsDestructive(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .sapHana) == .destructive)
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: .sapHana))
    }

    @Test("A delete without a WHERE inside a DO block is dangerous")
    func unfilteredDeleteIsDangerous() {
        #expect(QueryClassifier.isDangerousQuery("DO BEGIN DELETE FROM orders; END;", databaseType: .sapHana))
        #expect(!QueryClassifier.isDangerousQuery(
            "DO BEGIN DELETE FROM orders WHERE id = 1; END;",
            databaseType: .sapHana
        ))
    }

    @Test("Defining a procedure runs nothing, so a drop in its body stays a write")
    func definitionIsAWrite() {
        let sql = "CREATE PROCEDURE p AS BEGIN DROP TABLE users; END;"
        let classification = QueryClassifier.classify(sql, databaseType: .sapHana)

        #expect(classification.tier == .write)
        #expect(!classification.reachesFilesystemOrExecutesCode)
    }

    @Test("A DO block refreshes the whole catalog")
    func doBlockRefreshesTheCatalog() {
        let effect = CatalogChangeClassifier.effect(
            of: "DO BEGIN CREATE TABLE t (a INT); END;",
            databaseType: .sapHana
        )

        #expect(effect.kinds == .everything)
    }

    @Test("An external client cannot send a DO block")
    func externalGateRefusesDoBlocks() {
        let statement = ExternalStatementGate.Statement(
            sql: "DO BEGIN SELECT 1 FROM DUMMY; END;",
            connectionId: UUID(),
            databaseType: .sapHana,
            externalAccess: .readWrite,
            loadsExtensions: false,
            allowsDestructive: false
        )

        #expect(throws: ExternalStatementGateError.self) {
            try ExternalStatementGate.classify(statement)
        }
    }

    @Test("A DO on another engine does not swallow the statement after it")
    func otherEnginesKeepSplittingAfterDo() {
        let sql = "DO SLEEP(1); DROP TABLE users;"

        #expect(QueryClassifier.isMultiStatement(sql, databaseType: .mysql))
        #expect(QueryClassifier.classifyTier(sql, databaseType: .mysql) == .destructive)
    }
}

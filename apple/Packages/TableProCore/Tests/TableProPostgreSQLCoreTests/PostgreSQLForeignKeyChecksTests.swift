import Foundation
import TableProPostgreSQLCore
import Testing

struct PostgreSQLForeignKeyChecksTests {
    @Test("The foreign key switch swallows a refused SET, both ways")
    func switchSwallowsRefusal() {
        #expect(PostgreSQLForeignKeyChecks.disableStatements == [
            "DO $$ BEGIN SET session_replication_role = replica; EXCEPTION WHEN insufficient_privilege THEN NULL; END $$",
        ])
        #expect(PostgreSQLForeignKeyChecks.enableStatements == [
            "DO $$ BEGIN SET session_replication_role = DEFAULT; EXCEPTION WHEN insufficient_privilege THEN NULL; END $$",
        ])
    }
}

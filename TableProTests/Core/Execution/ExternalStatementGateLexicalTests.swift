//
//  ExternalStatementGateLexicalTests.swift
//  TableProTests
//
//  A read-only external client used to get a whole script past the gate by opening it with a read and hiding the
//  rest behind a quote the engine closes and the app did not. Each text here ran its hidden DROP on the live engine
//  named in the test, measured on 2026-09-19.
//

import Foundation
@testable import TablePro
import Testing

@Suite("External statement gate lexing")
struct ExternalStatementGateLexicalTests {
    private func refusal(
        _ sql: String,
        databaseType: DatabaseType,
        allowsMultiStatement: Bool
    ) -> ExternalStatementGateError? {
        let statement = ExternalStatementGate.Statement(
            sql: sql,
            connectionId: UUID(),
            databaseType: databaseType,
            externalAccess: .readOnly,
            allowsDestructive: false,
            allowsMultiStatement: allowsMultiStatement,
            destructiveAlternative: nil
        )
        do {
            _ = try ExternalStatementGate.classify(statement)
            return nil
        } catch let error as ExternalStatementGateError {
            return error
        } catch {
            return nil
        }
    }

    @Test("A hidden DROP is refused to a read-only client even when it may send several statements", arguments: [
        (DatabaseType.postgresql, "SELECT 'C:\\' AS p; DROP TABLE users"),
        (DatabaseType.postgresql, "SELECT 1 /* /* */ ' */; DROP TABLE users; --'"),
        (DatabaseType.duckdb, "SELECT $$it's$$; DROP TABLE users; SELECT 'x'"),
        (DatabaseType.mssql, "SELECT [it's] FROM t; DROP TABLE users; SELECT 'x'"),
        (DatabaseType.dameng, "SELECT 'a\\' FROM DUAL; DROP TABLE users; --'"),
    ])
    func hiddenDropIsRefused(engine: DatabaseType, sql: String) {
        #expect(refusal(sql, databaseType: engine, allowsMultiStatement: false) != nil)
        #expect(refusal(sql, databaseType: engine, allowsMultiStatement: true) == .denied(
            String(localized: "This connection is read only for external clients.")
        ))
    }

    @Test("One whole literal is one statement a read-only client may send", arguments: [
        (DatabaseType.postgresql, "SELECT $$a;b$$"),
        (DatabaseType.duckdb, "SELECT $tag$a;b$tag$"),
        (DatabaseType.mssql, "SELECT [a;b] FROM t"),
    ])
    func wholeLiteralPasses(engine: DatabaseType, sql: String) {
        #expect(refusal(sql, databaseType: engine, allowsMultiStatement: false) == nil)
    }
}

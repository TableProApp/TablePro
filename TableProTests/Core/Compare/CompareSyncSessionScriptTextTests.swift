//
//  CompareSyncSessionScriptTextTests.swift
//  TableProTests
//
//  The saved script used to be every statement joined by a newline. SQL*Plus ran its first DROP
//  and buffered the rest without a word, so the trigger it had just dropped never came back.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
final class CompareSyncSessionScriptTextTests {
    private static let callTrigger = "CREATE OR REPLACE TRIGGER T BEFORE INSERT ON X FOR EACH ROW\nCALL P(:NEW.ID)"

    private func session(target databaseType: DatabaseType, statements: [SyncStatement]) -> CompareSyncSession {
        let session = CompareSyncSession(connectionsProvider: { [] })
        session.target = DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "APP", schema: nil),
            connectionName: "target",
            databaseType: databaseType,
            safeModeLevel: .silent,
            color: .blue
        )
        session.statements = statements
        return session
    }

    private func statement(_ sql: String, refused: Bool = false) -> SyncStatement {
        SyncStatement(
            sql: sql,
            objectName: "T",
            summary: sql,
            hazards: refused ? [SyncHazard(kind: .dataLoss, severity: .refusedByDefault, explanation: "")] : []
        )
    }

    @Test
    func theSavedScriptIsWrittenForTheTargetsOwnClient() {
        let oracle = session(target: .oracle, statements: [
            statement("DROP TRIGGER \"T\""),
            statement(Self.callTrigger),
        ])

        #expect(oracle.scriptText == "DROP TRIGGER \"T\";\n\(Self.callTrigger)\n/")
        #expect(oracle.statements.map(\.sql) == ["DROP TRIGGER \"T\"", Self.callTrigger])
    }

    @Test
    func theApplySheetShowsOnlyWhatWillRun() {
        let oracle = session(target: .oracle, statements: [
            statement("DROP TABLE \"OLD\"", refused: true),
            statement(Self.callTrigger),
        ])

        #expect(oracle.runnableScriptText == "\(Self.callTrigger)\n/")
        #expect(oracle.scriptText.hasPrefix("DROP TABLE \"OLD\";\n"))
    }
}

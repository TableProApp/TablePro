//
//  CompareSyncSessionScriptTextTests.swift
//  TableProTests
//
//  The saved script used to be every statement joined by a newline. SQL*Plus ran its first DROP
//  and buffered the rest without a word, so the trigger it had just dropped never came back.
//

@testable import TablePro
import XCTest

@MainActor
final class CompareSyncSessionScriptTextTests: XCTestCase {
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

    func testTheSavedScriptIsWrittenForTheTargetsOwnClient() {
        let oracle = session(target: .oracle, statements: [
            statement("DROP TRIGGER \"T\""),
            statement(Self.callTrigger),
        ])

        XCTAssertEqual(oracle.scriptText, "DROP TRIGGER \"T\";\n\(Self.callTrigger)\n/")
        XCTAssertEqual(oracle.statements.map(\.sql), ["DROP TRIGGER \"T\"", Self.callTrigger])
    }

    func testTheApplySheetShowsOnlyWhatWillRun() {
        let oracle = session(target: .oracle, statements: [
            statement("DROP TABLE \"OLD\"", refused: true),
            statement(Self.callTrigger),
        ])

        XCTAssertEqual(oracle.runnableScriptText, "\(Self.callTrigger)\n/")
        XCTAssertTrue(oracle.scriptText.hasPrefix("DROP TABLE \"OLD\";\n"))
    }
}

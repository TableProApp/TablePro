//
//  StartupCommandWarningTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct ServerRefusal: PluginDriverError {
    let pluginErrorMessage: String
    let pluginSqlState: String?
}

// A startup command can be a safety rail, so a session that opened without one says so on the connection's warning.
@MainActor
struct StartupCommandWarningTests {
    @Test("A startup command the server refused is named on the session's warning, the ones that ran are not")
    func refusedStartupCommandIsNamed() async {
        let driver = MockDatabaseDriver()
        driver.failsStatementContaining = ("SET ROLE", DatabaseError.queryFailed("role \"app_ro\" does not exist"))

        let failures = await DatabaseManager.shared.applyTimeoutAndStartupCommands(
            on: driver,
            queryTimeoutSeconds: 0,
            startupCommands: "SET ROLE app_ro\nSET search_path = app",
            connectionName: "Reporting"
        )
        let warning = DatabaseManager.startupWarning(for: failures)

        #expect(failures.map { $0.statement } == ["SET ROLE app_ro"])
        #expect(warning?.contains("SET ROLE app_ro") == true)
        #expect(warning?.contains("SET search_path") == false)
    }

    // PostgreSQL can quote the statement's values back in its message, so only the code reaches the screen.
    @Test("The warning names the server's code, never its message")
    func warningShowsTheCodeNotTheMessage() {
        let refusal = ServerRefusal(
            pluginErrorMessage: "invalid value for parameter \"app.api_key\": \"sk-live-123\"", pluginSqlState: "22023"
        )
        let failure = StartupCommandFailure(statement: "SET app.api_key = 42", error: refusal)
        let warning = DatabaseManager.startupWarning(for: [failure])

        #expect(failure.code == "22023")
        #expect(warning?.contains("SET app.api_key = 42") == true)
        #expect(warning?.contains("22023") == true)
        #expect(warning?.contains("sk-live-123") == false)
    }

    @Test("Startup commands that all ran leave no warning")
    func successfulStartupCommandsLeaveNoWarning() async {
        let driver = MockDatabaseDriver()

        let failures = await DatabaseManager.shared.applyTimeoutAndStartupCommands(
            on: driver, queryTimeoutSeconds: 0, startupCommands: "SET search_path = app", connectionName: "Reporting"
        )

        #expect(DatabaseManager.startupWarning(for: failures) == nil)
    }

    @Test("Several failed startup commands are each named")
    func severalFailuresAreEachNamed() {
        let warning = DatabaseManager.startupWarning(for: [
            StartupCommandFailure(statement: "SET ROLE app_ro", code: "42704"),
            StartupCommandFailure(statement: "SET default_transaction_read_only = on", code: nil),
        ])

        #expect(warning?.contains("SET ROLE app_ro (42704)") == true)
        #expect(warning?.contains("SET default_transaction_read_only = on") == true)
    }

    // A startup command can carry a password or a key, and the banner is on screen, screen sharing included.
    @Test("A failed startup command is shown only up to its first literal or credential clause")
    func shownStatementStopsBeforeSecrets() {
        #expect(DatabaseManager.shownStatement("SELECT set_config('app.api_key', 'sk-live-123', false)")
            == "SELECT set_config(…")
        #expect(DatabaseManager.shownStatement("SET ROLE reporting IDENTIFIED BY hunter2") == "SET ROLE reporting…")
        #expect(DatabaseManager.shownStatement("ALTER USER app WITH PASSWORD 'x'") == "ALTER USER app WITH…")
        #expect(DatabaseManager.shownStatement("SET search_path = app") == "SET search_path = app")

        let warning = DatabaseManager.startupWarning(for: [
            StartupCommandFailure(statement: "SET ROLE reporting IDENTIFIED BY hunter2", code: "28000"),
        ])
        #expect(warning?.contains("hunter2") == false)
    }

    @Test("A reconnect whose startup commands all ran drops the banner about the session before it")
    func cleanReconnectClearsTheStartupWarning() {
        let connectionId = UUID()
        let manager = DatabaseManager.shared
        defer { manager.reportedStartupFailures.removeValue(forKey: connectionId) }

        let failed = manager.openingWarning(
            driver: MockDatabaseDriver(),
            startupFailures: [StartupCommandFailure(statement: "SET ROLE app_ro", code: "42704")],
            for: connectionId
        )
        let clean = manager.openingWarning(driver: MockDatabaseDriver(), startupFailures: [], for: connectionId)

        #expect(failed?.contains("SET ROLE app_ro") == true)
        #expect(clean == nil)
        #expect(manager.reportedStartupFailures[connectionId]?.isEmpty == true)
    }

    @Test("The login's warning and the startup warning are both kept")
    func warningsAreJoined() {
        #expect(DatabaseManager.joinedWarning(["ORA-28002", nil, "startup"]) == "ORA-28002\n\nstartup")
        #expect(DatabaseManager.joinedWarning([nil, ""]) == nil)
    }

    // The pool opens entries for as long as the window is open, so a failure it was already told about stays dismissed.
    @Test("A pool or lane session's failed startup command reaches the window once")
    func poolFailureIsReportedOnce() {
        let connection = TestFixtures.makeConnection(name: "Startup rail")
        let manager = DatabaseManager.shared
        manager.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { manager.removeSession(for: connection.id) }
        let role = StartupCommandFailure(statement: "SET ROLE app_ro", code: "42704")
        let path = StartupCommandFailure(statement: "SET search_path = app", code: "3F000")

        manager.reportStartupFailures([role], for: connection.id)
        #expect(manager.session(for: connection.id)?.connectionWarning?.contains("SET ROLE app_ro") == true)

        manager.dismissConnectionWarning(for: connection.id)
        manager.reportStartupFailures([role], for: connection.id)
        #expect(manager.session(for: connection.id)?.connectionWarning == nil)

        manager.reportStartupFailures([role, path], for: connection.id)
        let warning = manager.session(for: connection.id)?.connectionWarning
        #expect(warning?.contains("SET search_path = app") == true)
        #expect(warning?.contains("SET ROLE") == false)
    }
}

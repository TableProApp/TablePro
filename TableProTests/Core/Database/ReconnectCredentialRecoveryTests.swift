import Testing
@testable import TablePro
import TableProPluginKit

@Suite("Reconnect credential recovery", .serialized)
@MainActor
struct ReconnectCredentialRecoveryTests {
    @Test("Authentication failures are detected from SQLSTATE")
    func detectsAuthFailureFromSQLState() {
        let error = FakePluginAuthError(
            pluginErrorMessage: "Access denied",
            pluginErrorCode: nil,
            pluginSqlState: "28000"
        )

        #expect(DatabaseManager.shared.isAuthenticationFailure(error))
    }

    @Test("Prompt-for-password connections retry with fresh password")
    func retriesWithFreshPassword() async {
        let manager = DatabaseManager.shared
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.promptForPassword = true
        let session = ConnectionSession(connection: connection)
        let error = FakePluginAuthError(
            pluginErrorMessage: "Access denied",
            pluginErrorCode: 1045,
            pluginSqlState: "28000"
        )

        let resolution = await manager.reconnectCredentialResolution(
            for: session,
            error: error,
            currentPassword: "expired-secret",
            prompt: { _, _, _ in "fresh-secret" }
        )

        #expect(resolution == .retry("fresh-secret"))
    }

    @Test("Cancelling the prompt aborts reconnect recovery")
    func abortsWhenPromptCancelled() async {
        let manager = DatabaseManager.shared
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.promptForPassword = true
        let session = ConnectionSession(connection: connection)
        let error = FakePluginAuthError(
            pluginErrorMessage: "Access denied",
            pluginErrorCode: 1045,
            pluginSqlState: "28000"
        )

        let resolution = await manager.reconnectCredentialResolution(
            for: session,
            error: error,
            currentPassword: "expired-secret",
            prompt: { _, _, _ in nil }
        )

        #expect(resolution == .abort)
    }

    @Test("Non-authentication errors fail without prompting")
    func nonAuthErrorFailsWithoutPrompting() async {
        let manager = DatabaseManager.shared
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.promptForPassword = true
        let session = ConnectionSession(connection: connection)
        let error = FakePluginAuthError(
            pluginErrorMessage: "Lost connection to server",
            pluginErrorCode: 2013,
            pluginSqlState: "HY000"
        )

        var didPrompt = false
        let resolution = await manager.reconnectCredentialResolution(
            for: session,
            error: error,
            currentPassword: "cached-secret",
            prompt: { _, _, _ in
                didPrompt = true
                return "fresh-secret"
            }
        )

        #expect(resolution == .fail)
        #expect(didPrompt == false)
    }

    @Test("Re-entering the same password fails instead of looping")
    func samePasswordFails() async {
        let manager = DatabaseManager.shared
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.promptForPassword = true
        let session = ConnectionSession(connection: connection)
        let error = FakePluginAuthError(
            pluginErrorMessage: "Access denied",
            pluginErrorCode: 1045,
            pluginSqlState: "28000"
        )

        let resolution = await manager.reconnectCredentialResolution(
            for: session,
            error: error,
            currentPassword: "expired-secret",
            prompt: { _, _, _ in "expired-secret" }
        )

        #expect(resolution == .fail)
    }
}

private struct FakePluginAuthError: PluginDriverError {
    let pluginErrorMessage: String
    let pluginErrorCode: Int?
    let pluginSqlState: String?
    var errorDescription: String? { pluginErrorMessage }
}

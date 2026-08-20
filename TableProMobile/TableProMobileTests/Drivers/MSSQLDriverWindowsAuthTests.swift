import XCTest
import TableProDatabase
import TableProModels
@testable import TableProMobile

/// Deterministic tests for how the iOS MSSQL driver treats Windows Authentication.
/// Kerberos is macOS only; the iOS FreeTDS build has no GSS support, so the driver must
/// reject a synced Windows-auth connection before any network access. No server needed.
final class MSSQLDriverWindowsAuthTests: XCTestCase {
    private func connection(authMethod: String) -> DatabaseConnection {
        DatabaseConnection(
            name: "kerberos",
            type: .mssql,
            host: "sql.contoso.com",
            port: 1433,
            username: "",
            database: "master",
            additionalFields: ["mssqlAuthMethod": authMethod]
        )
    }

    func testWindowsAuthIsRejectedBeforeConnecting() async {
        let driver = MSSQLDriver(connection: connection(authMethod: "windows"), password: nil)
        do {
            try await driver.connect()
            XCTFail("Windows Authentication should be rejected on iOS")
        } catch let error as DatabaseError {
            XCTAssertTrue(
                error.message.contains("Windows Authentication"),
                "Expected the Windows-auth rejection, got: \(error.message)"
            )
        } catch {
            XCTFail("Expected a DatabaseError, got \(error)")
        }
    }

    func testSqlAuthDriverConstructsWithoutRejection() {
        _ = MSSQLDriver(connection: connection(authMethod: "sql"), password: "secret")
    }
}

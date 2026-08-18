import TableProDatabase
import TableProModels
import TableProPluginKit
import XCTest

@testable import TableProMobile

/// Deterministic tests for Microsoft Entra ID on the iOS MSSQL driver. The driver resolves a
/// token before it opens a socket, so a connection that cannot produce one fails at the token
/// step with no server and no network.
final class MSSQLDriverEntraAuthTests: XCTestCase {
    private func connection(fields: [String: String]) -> DatabaseConnection {
        DatabaseConnection(
            name: "entra",
            type: .mssql,
            host: "contoso.database.windows.net",
            port: 1_433,
            username: "",
            database: "master",
            additionalFields: fields
        )
    }

    func testEntraWithoutClientIDReportsNotConfigured() async {
        let driver = MSSQLDriver(
            connection: connection(fields: ["mssqlAuthMethod": "entra"]),
            password: nil
        )
        do {
            try await driver.connect()
            XCTFail("A connection with no client ID should not reach the server")
        } catch let error as EntraOAuthError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Expected EntraOAuthError.notConfigured, got \(error)")
        }
    }

    func testEntraWithClientIDButNoStoredTokenAsksForSignIn() async {
        let driver = MSSQLDriver(
            connection: connection(fields: [
                "mssqlAuthMethod": "entra",
                EntraField.clientId: "11111111-2222-3333-4444-555555555555",
                EntraField.tenantId: "contoso.onmicrosoft.com"
            ]),
            password: nil
        )
        do {
            try await driver.connect()
            XCTFail("A connection with no stored token should not reach the server")
        } catch let error as EntraOAuthError {
            XCTAssertTrue(
                error.needsSignIn,
                "Expected a state the sign-in prompt can recover, got \(error)"
            )
        } catch {
            XCTFail("Expected EntraOAuthError, got \(error)")
        }
    }

    func testEntraIsNoLongerRejectedOutright() async {
        let driver = MSSQLDriver(
            connection: connection(fields: ["mssqlAuthMethod": "entra"]),
            password: nil
        )
        do {
            try await driver.connect()
        } catch let error as DatabaseError {
            XCTAssertFalse(
                error.message.contains("isn't supported on iOS"),
                "Entra ID should reach the token step instead of being rejected"
            )
        } catch {
            // Any non-DatabaseError means it got past the platform rejection, which is the point.
        }
    }
}

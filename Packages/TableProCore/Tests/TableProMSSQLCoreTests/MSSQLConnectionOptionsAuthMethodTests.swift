@testable import TableProMSSQLCore
import Testing

@Suite("MSSQL auth method")
struct MSSQLConnectionOptionsAuthMethodTests {
    @Test("SQL Server auth passes username and password through")
    func sqlServerKeepsCredentials() {
        let options = MSSQLConnectionOptions(
            host: "db.example.com",
            user: "sa",
            password: "hunter2",
            database: "app",
            authMethod: .sqlServer
        )
        #expect(options.user == "sa")
        #expect(options.password == "hunter2")
        #expect(options.authMethod == .sqlServer)
    }

    @Test("Windows auth blanks username and password so FreeTDS takes the GSS path")
    func windowsBlanksCredentials() {
        let options = MSSQLConnectionOptions(
            host: "db.example.com",
            user: "sa",
            password: "hunter2",
            database: "app",
            authMethod: .windows
        )
        #expect(options.user == "")
        #expect(options.password == "")
        #expect(options.authMethod == .windows)
    }

    @Test("Entra ID blanks username and password so the token carries the login")
    func entraBlanksCredentials() {
        var options = MSSQLConnectionOptions(
            host: "db.example.com",
            user: "sa",
            password: "hunter2",
            database: "app",
            authMethod: .entra
        )
        #expect(options.user == "")
        #expect(options.password == "")
        #expect(options.authMethod == .entra)
        #expect(options.fedAuthToken == nil)

        options.fedAuthToken = "eyJhbGciOiJSUzI1NiJ9.payload.signature"
        #expect(options.fedAuthToken == "eyJhbGciOiJSUzI1NiJ9.payload.signature")
    }

    @Test("Default auth method is SQL Server")
    func defaultsToSqlServer() {
        let options = MSSQLConnectionOptions(host: "h", user: "u", password: "p", database: "d")
        #expect(options.authMethod == .sqlServer)
    }

    @Test("authMethod(from:) resolves the additional field, defaulting to SQL Server")
    func resolvesFromAdditionalFields() {
        #expect(MSSQLConnectionOptions.authMethod(from: ["mssqlAuthMethod": "windows"]) == .windows)
        #expect(MSSQLConnectionOptions.authMethod(from: ["mssqlAuthMethod": "sql"]) == .sqlServer)
        #expect(MSSQLConnectionOptions.authMethod(from: ["mssqlAuthMethod": "entra"]) == .entra)
        #expect(MSSQLConnectionOptions.authMethod(from: [:]) == .sqlServer)
        #expect(MSSQLConnectionOptions.authMethod(from: ["mssqlAuthMethod": "nonsense"]) == .sqlServer)
    }

    @Test("remaining millisecond budget takes precedence over configured seconds")
    func resolvesConnectTimeoutBudget() {
        #expect(MSSQLConnectionOptions.connectTimeoutMilliseconds(from: [
            "connectTimeoutMilliseconds": "1250",
            "connectTimeoutSeconds": "30"
        ]) == 1_250)
        #expect(MSSQLConnectionOptions.connectTimeoutMilliseconds(from: [
            "connectTimeoutSeconds": "2.5"
        ]) == 2_500)
    }

    @Test("connect timeout keeps the driver default for old hosts")
    func defaultsConnectTimeoutForOldHosts() {
        #expect(
            MSSQLConnectionOptions.connectTimeoutMilliseconds(from: [:])
                == MSSQLConnectionOptions.defaultLoginTimeoutSeconds * 1_000
        )
        #expect(
            MSSQLConnectionOptions.connectTimeoutMilliseconds(from: ["connectTimeoutMilliseconds": "invalid"])
                == MSSQLConnectionOptions.defaultLoginTimeoutSeconds * 1_000
        )
    }

    @Test("connect deadline reports one shrinking budget across phases")
    func deadlineKeepsOneBudget() async throws {
        let deadline = MSSQLConnectDeadline(timeoutMilliseconds: 500)
        let first = deadline.remainingMilliseconds
        try await Task.sleep(for: .milliseconds(20))
        let second = deadline.remainingMilliseconds

        #expect((1...500).contains(first))
        #expect(second < first)
    }
}

import Foundation
import TableProSQLQuoting

public struct MotherDuckConnectRequest: Sendable, Equatable {
    public var token: String
    public var database: String

    public init(token: String, database: String = "") {
        self.token = token
        self.database = database
    }
}

// Every refusal is thrown from init, before anything opens: with no token the extension starts a browser sign-in
// and holds the connect for a minute (measured on DuckDB v2.0.1).
public struct MotherDuckConnectPlan: Sendable, Equatable {
    public static let extensionName = "motherduck"

    public let database: String?
    // Run after the extension loads, which registers these settings.
    public let settingStatements: [String]
    public let attachStatement: String

    public init(_ request: MotherDuckConnectRequest) throws {
        let token = request.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw MotherDuckConnectError.missingToken }
        // A NUL would end the statement inside the literal, and DuckDB's parse error quotes the statement.
        guard !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MotherDuckConnectError.invalidToken
        }
        let database = request.database.trimmingCharacters(in: .whitespacesAndNewlines)
        // MotherDuck reads what follows ? in an md: path as connection parameters, saas_mode among them.
        guard !database.unicodeScalars.contains(where: { $0 == "?" || $0 == "#" || CharacterSet.controlCharacters.contains($0) })
        else {
            throw MotherDuckConnectError.invalidDatabase(name: database)
        }

        self.database = database.isEmpty ? nil : database
        settingStatements = [
            // Wins over a motherduck_token in the environment, and reads back as <redacted> (measured).
            "SET motherduck_token = \(SQLQuoting.stringLiteral(token))",
            // The first attach fixes the mode for the session, so it is set rather than left to the path's form.
            "SET motherduck_attach_mode = \(SQLQuoting.stringLiteral(database.isEmpty ? "workspace" : "single"))",
        ]
        attachStatement = "ATTACH \(SQLQuoting.stringLiteral("md:" + database))"
    }

    // The ATTACH does not stop for duckdb_interrupt (measured), so the attempt's deadline goes to MotherDuck.
    public static func connectionTimeoutStatement(remaining: Duration) -> String {
        let seconds = max(1, remaining.components.seconds)
        return "SET motherduck_connection_timeout = '\(seconds) seconds'"
    }

    public static let motherDuckCatalogsQuery = """
        SELECT database_name
        FROM duckdb_databases()
        WHERE type = 'motherduck'
        ORDER BY database_name
        """

    // An ATTACH from an in-memory DuckDB leaves the session on memory; this moves it to the account's default.
    public static let useDefaultStatement = "PRAGMA md_use_default"

    // A share path attaches under the share's name, so the one catalog single mode attached stands in for it.
    public func catalogToUse(among catalogs: [String]) -> String? {
        guard let database else { return catalogs.first }
        if let exact = catalogs.first(where: { $0 == database }) { return exact }
        if let folded = catalogs.first(where: { $0.lowercased() == database.lowercased() }) { return folded }
        return catalogs.count == 1 ? catalogs.first : nil
    }
}

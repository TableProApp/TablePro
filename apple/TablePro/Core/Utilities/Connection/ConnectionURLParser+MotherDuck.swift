//
//  ConnectionURLParser+MotherDuck.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension ConnectionURLParser {
    // MotherDuck's own connection string, `md:` or `md:<database>`, has no `//`. Its parameters, a token among them,
    // are left out: the Access Token is entered in its own field.
    static func parseMotherDuck(_ text: String) -> Result<ParsedConnectionURL, ConnectionURLParseError>? {
        guard text.lowercased().hasPrefix("md:"), !text.dropFirst(3).hasPrefix("//") else { return nil }
        let rest = text.dropFirst(3)
        // Not a URL: MotherDuck reads the name as written, so a % stays a %.
        let database = (rest.firstIndex(of: "?").map { String(rest[..<$0]) } ?? String(rest))
            .trimmingCharacters(in: .whitespaces)
        guard !database.unicodeScalars.contains(where: { $0 == "#" || CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.invalidURL)
        }
        return .success(ParsedConnectionURL(
            type: .duckdb,
            host: "",
            port: nil,
            database: "",
            username: "",
            password: "",
            sslMode: nil,
            disablesTLS: false,
            authSource: nil,
            sshHost: nil,
            sshPort: nil,
            sshUsername: nil,
            sshPassword: nil,
            usePrivateKey: nil,
            useSSHAgent: nil,
            sshNoAuth: nil,
            agentSocket: nil,
            connectionName: nil,
            redisDatabase: nil,
            statusColor: nil,
            envTag: nil,
            schema: nil,
            tableName: nil,
            isView: false,
            filterColumn: nil,
            filterOperation: nil,
            filterValue: nil,
            filterCondition: nil,
            oracleServiceName: nil,
            safeModeLevel: nil,
            useSrv: false,
            mongoQueryParams: [:],
            multiHost: nil,
            additionalFields: ["duckdbMode": "motherduck", "duckdbMotherDuckDatabase": database]
        ))
    }
}

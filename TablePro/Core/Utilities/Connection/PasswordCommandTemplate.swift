//
//  PasswordCommandTemplate.swift
//  TablePro
//

import Foundation

/// Fills a shared secret-manager command in from the connection it is being run for.
///
/// Every substituted value is shell-quoted on the way in. The command runs through
/// `/bin/bash -c`, so a connection named `x; rm -rf ~` would otherwise be a shell injection the
/// user typed into a name field months earlier, and a vault path is exactly the kind of value a
/// template interpolates.
enum PasswordCommandTemplate {
    struct Context: Equatable, Sendable {
        let name: String
        let host: String
        let port: Int
        let username: String
        let database: String
        let typeId: String

        init(name: String, host: String, port: Int, username: String, database: String, typeId: String) {
            self.name = name
            self.host = host
            self.port = port
            self.username = username
            self.database = database
            self.typeId = typeId
        }

        /// The address the server answers on, not the loopback port a tunnel happens to be using
        /// this run. A vault path keyed on the tunnel's port would name a different secret on
        /// every connect, because `LoopbackPort` picks a free one each time.
        init(connection: DatabaseConnection) {
            self.init(
                name: connection.name,
                host: connection.preTunnelHost ?? connection.host,
                port: connection.preTunnelPort ?? connection.port,
                username: connection.username,
                database: connection.database,
                typeId: connection.type.pluginTypeId
            )
        }
    }

    struct Placeholder: Identifiable {
        let token: String
        let summary: String

        var id: String { token }
    }

    static let placeholders: [Placeholder] = [
        Placeholder(token: "{name}", summary: String(localized: "Connection name")),
        Placeholder(token: "{host}", summary: String(localized: "Server host")),
        Placeholder(token: "{port}", summary: String(localized: "Server port")),
        Placeholder(token: "{user}", summary: String(localized: "Username")),
        Placeholder(token: "{database}", summary: String(localized: "Database name")),
        Placeholder(token: "{type}", summary: String(localized: "Database type")),
    ]

    /// One pass over the template, so a value that itself contains `{host}` is never expanded a
    /// second time. An unknown brace group is copied through untouched, which is what leaves
    /// `${AWS_PROFILE}` and a `jq '{a}'` filter working.
    static func expand(_ template: String, with context: Context) -> String {
        var result = ""
        var index = template.startIndex

        while index < template.endIndex {
            let character = template[index]
            guard character == "{",
                  let close = template[index...].firstIndex(of: "}") else {
                result.append(character)
                index = template.index(after: index)
                continue
            }

            let token = String(template[index...close])
            guard let value = value(forToken: token, in: context) else {
                result.append(character)
                index = template.index(after: index)
                continue
            }

            result.append(PasswordSourceResolver.shellQuote(value))
            index = template.index(after: close)
        }

        return result
    }

    private static func value(forToken token: String, in context: Context) -> String? {
        switch token {
        case "{name}": return context.name
        case "{host}": return context.host
        case "{port}": return String(context.port)
        case "{user}": return context.username
        case "{database}": return context.database
        case "{type}": return context.typeId
        default: return nil
        }
    }
}

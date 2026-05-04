//
//  DeeplinkParser.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum DeeplinkError: Error, LocalizedError, Equatable {
    case unknownScheme(String)
    case unknownHost(String)
    case malformedPath(String)
    case missingRequiredParam(String)
    case invalidUUID(String)
    case sqlTooLong(Int, limit: Int)
    case unsupportedDatabaseType(String)

    internal var errorDescription: String? {
        switch self {
        case .unknownScheme(let scheme):
            return String(format: String(localized: "Unknown URL scheme: %@"), scheme)
        case .unknownHost(let host):
            return String(format: String(localized: "Unknown deep link host: %@"), host)
        case .malformedPath(let path):
            return String(format: String(localized: "Malformed deep link path: %@"), path)
        case .missingRequiredParam(let name):
            return String(format: String(localized: "Missing required parameter: %@"), name)
        case .invalidUUID(let raw):
            return String(format: String(localized: "Invalid UUID: %@"), raw)
        case .sqlTooLong(let length, let limit):
            return String(
                format: String(localized: "SQL is too long: %d characters (limit %d)"),
                length, limit
            )
        case .unsupportedDatabaseType(let raw):
            return String(format: String(localized: "Unsupported database type: %@"), raw)
        }
    }
}

internal enum DeeplinkParser {
    internal static let sqlLengthLimit = 51_200

    internal static func parse(_ url: URL) -> Result<LaunchIntent, DeeplinkError> {
        guard url.scheme == "tablepro" else {
            return .failure(.unknownScheme(url.scheme ?? ""))
        }
        let host = url.host(percentEncoded: false) ?? ""
        switch host {
        case "connect":
            return parseConnect(url)
        case "import":
            return parseImport(url)
        case "integrations":
            return parseIntegrations(url)
        default:
            return .failure(.unknownHost(host))
        }
    }

    private static func parseConnect(_ url: URL) -> Result<LaunchIntent, DeeplinkError> {
        let segments = pathSegments(url)
        var cursor = PathCursor(segments: segments)

        guard let firstRaw = cursor.next() else {
            return .failure(.malformedPath(url.path))
        }
        guard let connectionId = UUID(uuidString: firstRaw) else {
            return .failure(.invalidUUID(firstRaw))
        }

        guard let head = cursor.peek() else {
            return .success(.openConnection(connectionId))
        }

        switch head {
        case "table":
            cursor.advance()
            guard let table = cursor.next(), !table.isEmpty else {
                return .failure(.malformedPath(url.path))
            }
            guard cursor.atEnd else { return .failure(.malformedPath(url.path)) }
            return .success(.openTable(
                connectionId: connectionId,
                database: nil,
                schema: nil,
                table: table,
                isView: false
            ))

        case "database":
            cursor.advance()
            guard let database = cursor.next(), !database.isEmpty else {
                return .failure(.malformedPath(url.path))
            }
            return parseDatabaseTail(
                connectionId: connectionId, database: database, cursor: &cursor, fullPath: url.path
            )

        case "query":
            cursor.advance()
            guard cursor.atEnd else { return .failure(.malformedPath(url.path)) }
            return parseQuery(url: url, connectionId: connectionId)

        default:
            return .failure(.malformedPath(url.path))
        }
    }

    private static func parseDatabaseTail(
        connectionId: UUID,
        database: String,
        cursor: inout PathCursor,
        fullPath: String
    ) -> Result<LaunchIntent, DeeplinkError> {
        guard let next = cursor.next() else {
            return .failure(.malformedPath(fullPath))
        }
        switch next {
        case "schema":
            guard let schema = cursor.next(), !schema.isEmpty else {
                return .failure(.malformedPath(fullPath))
            }
            guard cursor.next() == "table",
                  let table = cursor.next(), !table.isEmpty else {
                return .failure(.malformedPath(fullPath))
            }
            guard cursor.atEnd else { return .failure(.malformedPath(fullPath)) }
            return .success(.openTable(
                connectionId: connectionId,
                database: database,
                schema: schema,
                table: table,
                isView: false
            ))

        case "table":
            guard let table = cursor.next(), !table.isEmpty else {
                return .failure(.malformedPath(fullPath))
            }
            guard cursor.atEnd else { return .failure(.malformedPath(fullPath)) }
            return .success(.openTable(
                connectionId: connectionId,
                database: database,
                schema: nil,
                table: table,
                isView: false
            ))

        default:
            return .failure(.malformedPath(fullPath))
        }
    }

    private static func parseQuery(url: URL, connectionId: UUID) -> Result<LaunchIntent, DeeplinkError> {
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let rawSQL = queryItems.first(where: { $0.name == "sql" })?.value,
              !rawSQL.isEmpty else {
            return .failure(.missingRequiredParam("sql"))
        }
        let length = (rawSQL as NSString).length
        guard length <= sqlLengthLimit else {
            return .failure(.sqlTooLong(length, limit: sqlLengthLimit))
        }
        return .success(.openQuery(connectionId: connectionId, sql: rawSQL))
    }

    private static func parseIntegrations(_ url: URL) -> Result<LaunchIntent, DeeplinkError> {
        let segments = pathSegments(url)
        var cursor = PathCursor(segments: segments)
        guard let action = cursor.next() else {
            return .failure(.malformedPath(url.path))
        }
        switch action {
        case "pair":
            return parsePair(url)
        case "start-mcp":
            return .success(.startMCPServer)
        default:
            return .failure(.malformedPath(url.path))
        }
    }

    private static func parsePair(_ url: URL) -> Result<LaunchIntent, DeeplinkError> {
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else {
            return .failure(.missingRequiredParam("client"))
        }
        func value(_ key: String) -> String? {
            queryItems.first(where: { $0.name == key })?.value
        }

        guard let clientName = value("client"), !clientName.isEmpty else {
            return .failure(.missingRequiredParam("client"))
        }
        guard let challenge = value("challenge"), !challenge.isEmpty else {
            return .failure(.missingRequiredParam("challenge"))
        }
        guard let redirectRaw = value("redirect"), !redirectRaw.isEmpty,
              let redirectURL = URL(string: redirectRaw) else {
            return .failure(.missingRequiredParam("redirect"))
        }

        let scopes = value("scopes")?.nilIfEmpty
        let connectionIds: Set<UUID>?
        if let csv = value("connection-ids")?.nilIfEmpty {
            let parsed = csv.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            connectionIds = parsed.isEmpty ? nil : Set(parsed)
        } else {
            connectionIds = nil
        }

        return .success(.pairIntegration(
            PairingRequest(
                clientName: clientName,
                challenge: challenge,
                redirectURL: redirectURL,
                requestedScopes: scopes,
                requestedConnectionIds: connectionIds
            )
        ))
    }

    private static func parseImport(_ url: URL) -> Result<LaunchIntent, DeeplinkError> {
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else {
            return .failure(.missingRequiredParam("name"))
        }
        func value(_ key: String) -> String? {
            queryItems.first(where: { $0.name == key })?.value
        }

        guard let name = value("name"), !name.isEmpty else {
            return .failure(.missingRequiredParam("name"))
        }
        guard let host = value("host"), !host.isEmpty else {
            return .failure(.missingRequiredParam("host"))
        }
        guard let typeStr = value("type") else {
            return .failure(.missingRequiredParam("type"))
        }

        let resolvedType: DatabaseType?
        if let direct = DatabaseType(validating: typeStr) {
            resolvedType = direct
        } else if let pluginMatch = PluginMetadataRegistry.shared.allRegisteredTypeIds()
            .first(where: { $0.lowercased() == typeStr.lowercased() }) {
            resolvedType = DatabaseType(rawValue: pluginMatch)
        } else {
            resolvedType = nil
        }
        guard let dbType = resolvedType else {
            return .failure(.unsupportedDatabaseType(typeStr))
        }

        let port = value("port").flatMap(Int.init) ?? dbType.defaultPort
        let username = value("username") ?? ""
        let database = value("database") ?? ""

        let sshConfig: ExportableSSHConfig?
        if value("ssh") == "1" {
            let jumpHosts: [ExportableJumpHost]?
            if let jumpJson = value("sshJumpHosts"),
               let data = jumpJson.data(using: .utf8) {
                jumpHosts = try? JSONDecoder().decode([ExportableJumpHost].self, from: data)
            } else {
                jumpHosts = nil
            }
            sshConfig = ExportableSSHConfig(
                enabled: true,
                host: value("sshHost") ?? "",
                port: value("sshPort").flatMap(Int.init),
                username: value("sshUsername") ?? "",
                authMethod: value("sshAuthMethod") ?? "password",
                privateKeyPath: value("sshPrivateKeyPath") ?? "",
                agentSocketPath: value("sshAgentSocketPath") ?? "",
                jumpHosts: jumpHosts,
                totpMode: value("sshTotpMode"),
                totpAlgorithm: value("sshTotpAlgorithm"),
                totpDigits: value("sshTotpDigits").flatMap(Int.init),
                totpPeriod: value("sshTotpPeriod").flatMap(Int.init)
            )
        } else {
            sshConfig = nil
        }

        let sslConfig: ExportableSSLConfig?
        if let sslMode = value("sslMode") {
            sslConfig = ExportableSSLConfig(
                mode: sslMode,
                caCertificatePath: value("sslCaCertPath"),
                clientCertificatePath: value("sslClientCertPath"),
                clientKeyPath: value("sslClientKeyPath")
            )
        } else {
            sslConfig = nil
        }

        var additionalFields: [String: String]?
        let afItems = queryItems.filter { $0.name.hasPrefix("af_") }
        if !afItems.isEmpty {
            var fields: [String: String] = [:]
            for item in afItems {
                let fieldKey = String(item.name.dropFirst(3))
                if !fieldKey.isEmpty, let fieldValue = item.value, !fieldValue.isEmpty {
                    fields[fieldKey] = fieldValue
                }
            }
            if !fields.isEmpty {
                additionalFields = fields
            }
        }

        let exportable = ExportableConnection(
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: dbType.rawValue,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: value("color"),
            tagName: value("tagName"),
            groupName: value("groupName"),
            sshProfileId: nil,
            safeModeLevel: value("safeModeLevel"),
            aiPolicy: value("aiPolicy"),
            additionalFields: additionalFields,
            redisDatabase: value("redisDatabase").flatMap(Int.init),
            startupCommands: value("startupCommands"),
            localOnly: value("localOnly") == "1" ? true : nil
        )

        return .success(.importConnection(exportable))
    }

    private static func pathSegments(_ url: URL) -> [String] {
        url.pathComponents
            .filter { $0 != "/" }
            .compactMap { $0.removingPercentEncoding }
    }
}

private struct PathCursor {
    private let segments: [String]
    private var index: Int = 0

    init(segments: [String]) {
        self.segments = segments
    }

    var atEnd: Bool {
        index >= segments.count
    }

    func peek() -> String? {
        guard index < segments.count else { return nil }
        return segments[index]
    }

    mutating func advance() {
        index += 1
    }

    mutating func next() -> String? {
        guard index < segments.count else { return nil }
        defer { index += 1 }
        return segments[index]
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

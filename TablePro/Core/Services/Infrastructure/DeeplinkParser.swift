//
//  DeeplinkParser.swift
//  TablePro
//

import Foundation
import os
import TableProImport
import TableProPluginKit

internal enum DeeplinkError: Error, LocalizedError, Equatable {
    case unknownScheme(String)
    case unknownHost(String)
    case malformedPath(String)
    case missingRequiredParam(String)
    case invalidParameter(String)
    case invalidUUID(String)
    case sqlTooLong(Int, limit: Int)
    case unsupportedDatabaseType(String)
    case invalidConnection(String)

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
        case .invalidParameter(let name):
            return String(format: String(localized: "Invalid parameter: %@"), name)
        case .invalidUUID(let raw):
            return String(format: String(localized: "Invalid UUID: %@"), raw)
        case .sqlTooLong(let length, let limit):
            return String(
                format: String(localized: "SQL is too long: %d characters (limit %d)"),
                length, limit
            )
        case .unsupportedDatabaseType(let raw):
            return String(format: String(localized: "Unsupported database type: %@"), raw)
        case .invalidConnection(let detail):
            return String(format: String(localized: "This connection link could not be read: %@"), detail)
        }
    }
}

internal enum DeeplinkParser {
    internal static let sqlLengthLimit = 51_200

    private static let logger = Logger(subsystem: "com.TablePro", category: "DeeplinkParser")

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
        case "settings":
            return parseSettings(url)
        default:
            return .failure(.unknownHost(host))
        }
    }

    /// Never fails: an unknown id or extra segments open the last-used pane, so a link to a pane
    /// or section added later still opens Settings on an older app.
    private static func parseSettings(_ url: URL) -> Result<LaunchIntent, DeeplinkError> {
        guard let identifier = pathSegments(url).first else {
            return .success(.openSettings(nil))
        }
        guard let pane = SettingsPane(urlIdentifier: identifier) else {
            logger.notice("Unknown settings pane id \(identifier, privacy: .public), opening the last-used pane")
            return .success(.openSettings(nil))
        }
        return .success(.openSettings(pane))
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

        let state = value("state")
        if let state, state.utf8.count > PairingRequest.maximumStateBytes {
            return .failure(.invalidParameter("state"))
        }

        let responseMode: PairingResponseMode
        if queryItems.contains(where: { $0.name == "response_mode" }) {
            guard let mode = PairingResponseMode(parameter: value("response_mode") ?? "") else {
                return .failure(.invalidParameter("response_mode"))
            }
            responseMode = mode
        } else {
            responseMode = .legacy
        }

        /// Only an absent parameter means every connection. Naming the parameter and then handing
        /// over something unreadable used to fall back to absent, which turned a request scoped to
        /// one connection into a request for all of them with the sheet pre-ticked to All
        /// Connections. So presence is the test, not a non-empty value, and an empty field is kept
        /// rather than dropped so it has to answer the same guard. (#2930)
        let connectionIds: Set<UUID>?
        if queryItems.contains(where: { $0.name == "connection-ids" }) {
            let csv = value("connection-ids") ?? ""
            var parsed: Set<UUID> = []
            for rawId in csv.split(separator: ",", omittingEmptySubsequences: false) {
                let trimmed = rawId.trimmingCharacters(in: .whitespaces)
                guard let connectionId = UUID(uuidString: trimmed) else {
                    return .failure(.invalidUUID(trimmed))
                }
                parsed.insert(connectionId)
            }
            connectionIds = parsed
        } else {
            connectionIds = nil
        }

        return .success(.pairIntegration(
            PairingRequest(
                clientName: clientName,
                challenge: challenge,
                redirectURL: redirectURL,
                requestedScopes: scopes,
                requestedConnectionIds: connectionIds,
                state: state,
                responseMode: responseMode
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
        func values(_ key: String) -> [String] {
            queryItems.filter { $0.name == key }.compactMap { $0.value }
        }

        guard let name = value("name"), !name.isEmpty else {
            return .failure(.missingRequiredParam("name"))
        }
        let givenHost = value("host") ?? ""
        guard let typeStr = value("type") else {
            return .failure(givenHost.isEmpty ? .missingRequiredParam("host") : .missingRequiredParam("type"))
        }

        guard let typeId = ConnectionTypeResolver.canonicalTypeId(
            typeStr,
            registeredTypeIds: Set(PluginMetadataRegistry.shared.allRegisteredTypeIds())
        ) else {
            return .failure(.unsupportedDatabaseType(typeStr))
        }
        let dbType = DatabaseType(rawValue: typeId)

        let afItems = queryItems.filter { $0.name.hasPrefix("af_") }
        var fields: [String: String] = [:]
        for item in afItems {
            let fieldKey = String(item.name.dropFirst(3))
            if !fieldKey.isEmpty, let fieldValue = item.value, !fieldValue.isEmpty {
                fields[fieldKey] = fieldValue
            }
        }

        // The generic `af_localSocketPath` form is read too, under the same rules as `socket`.
        let requestedSocket = MySQLLocalSocket.path(in: [
            MySQLLocalSocket.fieldKey: value("socket") ?? fields[MySQLLocalSocket.fieldKey] ?? ""
        ])
        fields.removeValue(forKey: MySQLLocalSocket.fieldKey)
        var socketPath: String?
        if let requestedSocket, dbType.supportsLocalSocket, value("ssh") != "1" {
            guard MySQLLocalSocket.issue(for: requestedSocket) == nil else {
                return .failure(.invalidParameter("socket"))
            }
            socketPath = requestedSocket
            fields[MySQLLocalSocket.fieldKey] = requestedSocket
        }
        let additionalFields: [String: String]? = fields.isEmpty ? nil : fields

        guard !givenHost.isEmpty || socketPath != nil else {
            return .failure(.missingRequiredParam("host"))
        }
        let host = givenHost.isEmpty ? "localhost" : givenHost

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
                totpPeriod: value("sshTotpPeriod").flatMap(Int.init),
                remoteFilePath: value("sshRemoteFilePath"),
                remoteFileAccess: value("sshRemoteFileAccess")
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

        var settings = ExportableConnection(
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: dbType.rawValue
        )
        settings.sshConfig = sshConfig
        settings.sslConfig = sslConfig
        settings.color = value("color")
        settings.iconName = value("icon")
        settings.safeModeLevel = value("safeModeLevel")
        settings.aiPolicy = value("aiPolicy")
        settings.connectTimeoutSeconds = value("connectTimeoutSeconds").flatMap(Int.init)
        settings.queryTimeoutSeconds = value("queryTimeoutSeconds").flatMap(Int.init)
        settings.additionalFields = additionalFields
        settings.redisDatabase = value("redisDatabase").flatMap(Int.init)
        settings.startupCommands = value("startupCommands")
        settings.localOnly = value("localOnly") == "1" ? true : nil

        var builder = ConnectionBundleBuilder(appVersion: ConnectionBundleExporter.bundledAppVersion)
        builder.addConnection(
            settings.sanitizedForImport().withoutTunnelCommand(),
            ref: "c1",
            groupPath: nonEmpty(values("groupName")).map { ConnectionBundleBuilder.GroupComponent(name: $0, color: nil) },
            tags: nonEmpty(values("tagName")).map { BundleTag(name: $0, color: nil) }
        )
        do {
            return .success(.importConnection(try builder.build()))
        } catch {
            return .failure(.invalidConnection(error.localizedDescription))
        }
    }

    private static func nonEmpty(_ names: [String]) -> [String] {
        names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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

import Foundation
import os
import TableProPluginKit
import TableProTrinoCore

final class TrinoPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    let config: DriverConnectionConfig
    let session: TrinoSessionState
    private let clientConfig: TrinoClientConfig
    private let lock = NSLock()
    private var _client: TrinoStatementClient?
    private var _serverVersion: String?

    static let logger = Logger(subsystem: "com.TablePro", category: "TrinoPluginDriver")

    init(config: DriverConnectionConfig) {
        self.config = config
        self.clientConfig = Self.makeClientConfig(config)
        self.session = TrinoSessionState(
            catalog: config.database.isEmpty ? nil : config.database,
            schema: Self.trimmedField(config.additionalFields["trinoSchema"])
        )
    }

    var capabilities: PluginCapabilities {
        [.multiSchema, .cancelQuery]
    }

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { session.schema }
    var serverVersion: String? { lock.withLock { _serverVersion } }

    var client: TrinoStatementClient? {
        lock.withLock { _client }
    }

    func connect() async throws {
        let transport = URLSessionTrinoTransport(verifyTLS: clientConfig.verifyTLS)
        let client = TrinoStatementClient(transport: transport, config: clientConfig, session: session)
        lock.withLock { _client = client }

        let result = try await client.execute("SELECT version()")
        if case .text(let version)? = result.rows.first?.first {
            lock.withLock { _serverVersion = "Trino \(version)" }
        } else {
            lock.withLock { _serverVersion = "Trino" }
        }
    }

    func disconnect() {
        lock.withLock { _client = nil }
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    func cancelQuery() throws {
        client?.cancel()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        guard let client else { throw TrinoError.notConnected }
        let start = Date()
        let result = try await client.execute(query)
        return pluginResult(result, executionTime: Date().timeIntervalSince(start))
    }

    private func pluginResult(_ result: TrinoResultSet, executionTime: TimeInterval) -> PluginQueryResult {
        guard !result.columns.isEmpty else {
            let message = Self.statusMessage(for: result)
            return PluginQueryResult(
                columns: ["status"],
                columnTypeNames: ["varchar"],
                rows: [[.text(message)]],
                rowsAffected: result.updateCount ?? 0,
                executionTime: executionTime,
                statusMessage: message
            )
        }
        return PluginQueryResult(
            columns: result.columns.map(\.name),
            columnTypeNames: result.columns.map(\.typeName),
            rows: result.rows.map { row in row.map(Self.cellValue) },
            rowsAffected: result.updateCount ?? 0,
            executionTime: executionTime
        )
    }

    static func cellValue(_ value: TrinoValue) -> PluginCellValue {
        switch value {
        case .null:
            return .null
        case .text(let text):
            return .text(text)
        case .bytes(let bytes):
            return .bytes(Data(bytes))
        }
    }

    private static func statusMessage(for result: TrinoResultSet) -> String {
        guard let updateType = result.updateType, !updateType.isEmpty else {
            return String(localized: "Statement executed")
        }
        guard let count = result.updateCount else {
            return updateType
        }
        return String(format: String(localized: "%1$@: %2$lld rows"), updateType, Int64(count))
    }

    private static func makeClientConfig(_ config: DriverConnectionConfig) -> TrinoClientConfig {
        let useTLS = config.ssl.isEnabled
        let port = config.port > 0 ? config.port : (useTLS ? 8_443 : 8_080)
        return TrinoClientConfig(
            host: config.host.isEmpty ? "localhost" : config.host,
            port: port,
            useTLS: useTLS,
            verifyTLS: !useTLS || config.ssl.verifiesCertificate,
            user: config.username,
            catalog: config.database.isEmpty ? nil : config.database,
            schema: trimmedField(config.additionalFields["trinoSchema"]),
            auth: resolveAuth(config)
        )
    }

    private static func resolveAuth(_ config: DriverConnectionConfig) -> TrinoAuth {
        switch config.additionalFields["trinoAuthMethod"] {
        case "jwt":
            let token = config.additionalFields["trinoJwtToken"] ?? ""
            return token.isEmpty ? .none : .jwt(token: token)
        default:
            return config.password.isEmpty ? .none : .basic(password: config.password)
        }
    }

    private static func trimmedField(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

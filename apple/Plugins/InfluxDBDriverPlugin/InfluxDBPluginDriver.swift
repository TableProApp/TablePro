import Foundation
import os
import TableProInfluxDBCore
import TableProPluginKit

internal final class InfluxDBPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "InfluxDBPluginDriver")

    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var connection: InfluxDBConnection?
    private var server: InfluxServerInfo?
    private var organization: String
    private var database: String
    private var columnCache: [String: [InfluxColumn]] = [:]
    private var influxQLDatabases: [String: String] = [:]
    let queryTimeout = HttpQueryTimeoutBox()

    init(config: DriverConnectionConfig) {
        self.config = config
        self.organization = (config.additionalFields[InfluxDBFieldID.organization] ?? "")
            .trimmingCharacters(in: .whitespaces)
        self.database = config.database.trimmingCharacters(in: .whitespaces)
    }

    var serverVersion: String? { lock.withLock { server?.version } }
    var supportsTransactions: Bool { false }
    var capabilities: PluginCapabilities { [.cancelQuery] }
    var currentDatabase: String? { lock.withLock { database.isEmpty ? nil : database } }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    // MARK: - Lifecycle

    func connect() async throws {
        let scheme = config.ssl.isEnabled ? "https" : "http"
        let host = config.host.isEmpty ? "localhost" : config.host
        let port = config.port > 0 ? config.port : InfluxDBPlugin.defaultPort
        let address = "\(scheme)://\(host.contains(":") ? "[\(host)]" : host):\(port)"
        guard let baseURL = URL(string: address) else { throw InfluxError.invalidURL(address) }

        let credentials = InfluxCredentials(token: config.additionalFields[InfluxDBFieldID.token])
        let skipTLS = config.additionalFields[InfluxDBFieldID.skipTLSVerify] == "true"
            || (config.ssl.isEnabled && !config.ssl.verifiesCertificate)
        let connectMilliseconds = PluginConnectTimeout.milliseconds(
            in: config.additionalFields,
            default: Int(HttpQueryTimeout.sessionBootstrapRequestTimeout * 1_000)
        )
        let deadline = PluginConnectDeadline(milliseconds: connectMilliseconds)
        let connection = InfluxDBConnection(
            baseURL: baseURL,
            credentials: credentials,
            skipTLSVerify: skipTLS,
            queryTimeout: queryTimeout
        )
        connection.open(connectTimeout: TimeInterval(connectMilliseconds) / 1_000)

        do {
            let ping = try await connection.send(
                InfluxRequests.ping(credentials: credentials),
                timeout: deadline.remainingSeconds()
            )
            guard ping.isSuccess else { throw InfluxDBConnection.error(for: ping) }
            let server = InfluxServerInfo(versionHeader: ping.header("X-Influxdb-Version"))
            lock.withLock {
                self.connection = connection
                self.server = server
                columnCache.removeAll()
            }
            if server.generation == .v2, lock.withLock({ organization.isEmpty }) {
                try await adoptOnlyOrganization(connection, timeout: deadline.remainingSeconds())
            }
            // `/ping` answers without a token, so the catalog call is what proves the token works.
            _ = try await fetchDatabases()
        } catch {
            lock.withLock {
                self.connection = nil
                self.server = nil
            }
            connection.close()
            throw error
        }
    }

    func disconnect() {
        let current = lock.withLock {
            let current = connection
            connection = nil
            server = nil
            columnCache.removeAll()
            return current
        }
        current?.close()
    }

    func ping() async throws {
        let (connection, server) = try requireConnection()
        if server.generation == .v1 {
            let response = try await connection.send(InfluxRequests.ping(credentials: connection.credentials))
            guard response.isSuccess else { throw InfluxDBConnection.error(for: response) }
            return
        }
        _ = try await fetchDatabases()
    }

    func cancelQuery() throws {
        lock.withLock { connection }?.cancelAll()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        queryTimeout.set(serverTimeoutSeconds: seconds)
    }

    func switchDatabase(to database: String) async throws {
        lock.withLock {
            self.database = database
            columnCache.removeAll()
        }
    }

    // MARK: - Queries

    func execute(query: String) async throws -> PluginQueryResult {
        let started = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "select 1" {
            try await ping()
            return PluginQueryResult(
                columns: ["ok"], columnTypeNames: [InfluxTypeName.integer], rows: [[.text("1")]],
                rowsAffected: 0, executionTime: Date().timeIntervalSince(started)
            )
        }
        let (_, server) = try requireConnection()
        let language = try InfluxLanguageRouter.language(for: trimmed, generation: server.generation)
        let table = try await run(trimmed, language: language)
        return PluginQueryResult(
            columns: table.columns,
            columnTypeNames: table.typeNames,
            rows: table.rows.map { row in row.map { $0.map(PluginCellValue.text) ?? .null } },
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(started)
        )
    }

    func run(_ statement: String, language: InfluxQueryLanguage) async throws -> InfluxResultTable {
        let (connection, server) = try requireConnection()
        let (database, organization) = lock.withLock { (self.database, self.organization) }
        if server.generation == .v3, database.isEmpty {
            throw InfluxError.missingDatabase
        }
        if language == .flux, organization.isEmpty {
            throw InfluxError.missingOrganization
        }
        // On 2.x InfluxQL names a DBRP mapping, which may differ from the bucket the sidebar shows.
        let target = server.generation == .v2 && language == .influxQL
            ? lock.withLock { influxQLDatabases[database] } ?? database
            : database
        let request = InfluxRequests.query(
            statement,
            language: language,
            database: target,
            organization: organization,
            generation: server.generation,
            credentials: connection.credentials
        )
        let response = try await connection.send(request)
        guard response.isSuccess else { throw InfluxDBConnection.error(for: response) }
        switch (server.generation, language) {
        case (.v3, _):
            return InfluxResponseDecoder.decodeV3CSV(String(bytes: response.data, encoding: .utf8) ?? "")
        case (_, .flux):
            return try InfluxResponseDecoder.decodeFluxCSV(String(bytes: response.data, encoding: .utf8) ?? "")
        default:
            return try InfluxResponseDecoder.decodeV1JSON(response.data)
        }
    }

    func requireConnection() throws -> (InfluxDBConnection, InfluxServerInfo) {
        guard let pair = lock.withLock({ connection.flatMap { conn in server.map { (conn, $0) } } }) else {
            throw InfluxError.notConnected
        }
        return pair
    }

    var currentOrganization: String {
        lock.withLock { organization }
    }

    var gridLanguage: InfluxQueryLanguage {
        lock.withLock { server?.generation.gridLanguage } ?? .sql
    }

    func remember(influxQLDatabases mapping: [String: String]) {
        lock.withLock { influxQLDatabases = mapping }
    }

    func cachedColumns(_ measurement: String) -> [InfluxColumn]? {
        lock.withLock { columnCache[measurement] }
    }

    func cache(_ columns: [InfluxColumn], for measurement: String) {
        lock.withLock { columnCache[measurement] = columns }
    }

    // MARK: - Organization

    /// 2.x scopes buckets and Flux to an organization. A token that sees exactly one needs no
    /// setting, which is the common case for a self-hosted server.
    private func adoptOnlyOrganization(_ connection: InfluxDBConnection, timeout: TimeInterval) async throws {
        let response = try await connection.send(
            InfluxRequests.listOrganizations(credentials: connection.credentials),
            timeout: timeout
        )
        guard response.isSuccess else { throw InfluxDBConnection.error(for: response) }
        let names = try InfluxCatalogDecoder.v2Organizations(response.data)
        guard names.count == 1, let only = names.first else { throw InfluxError.missingOrganization }
        lock.withLock { organization = only }
    }
}

import Foundation
import TableProInfluxDBCore
import TableProPluginKit

internal final class InfluxDBPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var connection: InfluxDBConnection?
    private var server: InfluxServerInfo?
    private var organization: String
    private var database: String
    private var schemas: [SchemaKey: [InfluxColumn]] = [:]
    private var influxQLTargets: [String: InfluxQLTarget] = [:]
    private var gridQueries = GridQueryMemo()
    let queryTimeout = HttpQueryTimeoutBox()

    private struct SchemaKey: Hashable {
        let database: String
        let measurement: String
    }

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
        let connectMilliseconds = PluginConnectTimeout.milliseconds(
            in: config.additionalFields,
            default: Int(HttpQueryTimeout.sessionBootstrapRequestTimeout * 1_000)
        )
        let deadline = PluginConnectDeadline(milliseconds: connectMilliseconds)
        let connection = InfluxDBConnection(
            baseURL: baseURL,
            credentials: credentials,
            skipTLSVerify: config.additionalFields[InfluxDBFieldID.skipTLSVerify] == "true"
                || (config.ssl.isEnabled && !config.ssl.verifiesCertificate),
            connectTimeout: TimeInterval(connectMilliseconds) / 1_000,
            queryTimeout: queryTimeout
        )

        do {
            let ping = try await connection.send(
                InfluxRequests.ping(credentials: credentials),
                timeout: deadline.remainingSeconds()
            )
            guard ping.isSuccess else { throw ping.error }
            let server = try InfluxServerInfo(versionHeader: ping.header("X-Influxdb-Version"), pingBody: ping.data)
            var organization = lock.withLock { self.organization }
            if server.generation == .v2, organization.isEmpty {
                organization = try await onlyOrganization(connection, timeout: deadline.remainingSeconds())
            }
            try await checkToken(connection, server: server, organization: organization, timeout: deadline.remainingSeconds())
            lock.withLock {
                self.connection = connection
                self.server = server
                self.organization = organization
                schemas.removeAll()
                influxQLTargets.removeAll()
                gridQueries = GridQueryMemo()
            }
        } catch {
            connection.close()
            throw error
        }
    }

    func disconnect() {
        let current = lock.withLock {
            defer {
                connection = nil
                server = nil
                schemas.removeAll()
                influxQLTargets.removeAll()
                gridQueries = GridQueryMemo()
            }
            return connection
        }
        current?.close()
    }

    func ping() async throws {
        let (connection, server) = try requireConnection()
        try await checkToken(connection, server: server, organization: currentOrganization, timeout: nil)
    }

    func cancelQuery() throws {
        lock.withLock { connection }?.cancelAll()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        queryTimeout.set(serverTimeoutSeconds: seconds)
    }

    func switchDatabase(to database: String) async throws {
        lock.withLock { self.database = database }
    }

    // 3.x checks the token on `/ping` itself; 2.x answers `/ping` without one.
    private func checkToken(
        _ connection: InfluxDBConnection,
        server: InfluxServerInfo,
        organization: String,
        timeout: TimeInterval?
    ) async throws {
        let request: InfluxRequest
        switch server.generation {
        case .v3:
            request = InfluxRequests.ping(credentials: connection.credentials, generation: .v3)
        case .v2:
            request = InfluxRequests.v2TokenCheck(organization: organization, credentials: connection.credentials)
        }
        let response = try await connection.send(request, timeout: timeout)
        guard response.isSuccess else { throw response.error }
    }

    // 2.x scopes buckets and Flux to an organization; a token that sees exactly one needs no setting.
    private func onlyOrganization(_ connection: InfluxDBConnection, timeout: TimeInterval) async throws -> String {
        let response = try await connection.send(
            InfluxRequests.v2Organizations(credentials: connection.credentials),
            timeout: timeout
        )
        guard response.isSuccess else { throw response.error }
        let names = try InfluxCatalogDecoder.v2Organizations(response.data)
        guard names.count == 1, let only = names.first else { throw InfluxError.missingOrganization }
        return only
    }

    // MARK: - Queries

    func execute(query: String) async throws -> PluginQueryResult {
        let started = Date()
        let (_, server) = try requireConnection()
        let table: InfluxResultTable
        if let remembered = lock.withLock({ gridQueries[query] }) {
            table = try await runGrid(remembered.query, hostKinds: remembered.hostKinds, generation: server.generation)
        } else {
            table = try await run(InfluxStatement.route(query, generation: server.generation))
        }
        return PluginQueryResult(
            columns: table.columns,
            columnTypeNames: table.typeNames,
            rows: table.rows.map { row in row.map { $0.map(PluginCellValue.text) ?? .null } },
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(started),
            columnMeta: zip(table.columns, table.typeNames).map { name, typeName in
                Self.columnInfo(name: name, typeName: typeName, role: nil)
            }
        )
    }

    // A grid statement built before the measurement's columns were known is written again from them here.
    // A filter on a column the cached schema lacks means the measurement gained one since; the schema is read again.
    private func runGrid(
        _ grid: InfluxGridQuery,
        hostKinds: [String: InfluxColumnKind],
        generation: InfluxGeneration
    ) async throws -> InfluxResultTable {
        var schema = try await columns(of: grid.measurement)
        let known = Set(schema.map(\.name))
        if grid.filters.contains(where: { !known.contains($0.column) }) {
            schema = try await loadColumns(of: grid.measurement)
        }
        let kinds = hostKinds.merging(Self.kinds(of: schema)) { _, schema in schema }
        let language = generation.gridLanguage
        guard let text = grid.statement(language: language, kinds: kinds) else {
            throw InfluxError.filterNotExpressible(language)
        }
        var table = try await run(InfluxStatement.route(text, generation: generation)).typed(by: schema)
        if table.columns.isEmpty {
            let names = grid.projection.isEmpty ? schema.map(\.name) : grid.projection
            let types = Dictionary(schema.map { ($0.name, $0.typeName) }, uniquingKeysWith: { first, _ in first })
            table = InfluxResultTable(
                columns: names,
                typeNames: names.map { types[$0] ?? InfluxTypeName.string },
                rows: []
            )
        }
        return table
    }

    func run(_ statement: InfluxStatement) async throws -> InfluxResultTable {
        let (connection, server) = try requireConnection()
        let (database, organization) = lock.withLock { (self.database, self.organization) }
        if server.generation == .v3, statement.language == .sql, database.isEmpty {
            throw InfluxError.missingDatabase
        }
        if statement.language == .flux, organization.isEmpty {
            throw InfluxError.missingOrganization
        }
        var target = InfluxQLTarget(database: database, retentionPolicy: nil)
        if statement.language == .influxQL, let resolved = try await influxQLTarget() {
            target = resolved
        }
        let request = try InfluxRequests.query(
            statement,
            database: target.database,
            retentionPolicy: target.retentionPolicy,
            organization: organization,
            generation: server.generation,
            credentials: connection.credentials
        )
        let response = try await connection.send(request)
        guard response.isSuccess else { throw response.error }
        switch (server.generation, statement.language) {
        case (.v3, _):
            return InfluxResponseDecoder.decodeV3CSV(response.data)
        case (_, .flux):
            return try InfluxResponseDecoder.decodeFluxCSV(response.data)
        default:
            return try InfluxResponseDecoder.decodeV1JSON(response.data)
        }
    }

    // A lookup that fails leaves the bucket name, which the virtual mapping of any bucket without a `/` still resolves.
    func influxQLTarget() async throws -> InfluxQLTarget? {
        guard let (connection, server) = try? requireConnection(), server.generation == .v2 else { return nil }
        let (bucket, organization) = lock.withLock { (database, self.organization) }
        guard !bucket.isEmpty else { return nil }
        if let known = lock.withLock({ influxQLTargets[bucket] }) { return known }
        let fallback = InfluxQLTarget(database: bucket, retentionPolicy: nil)
        do {
            let found = try await connection.send(
                InfluxRequests.v2Bucket(named: bucket, organization: organization, credentials: connection.credentials)
            )
            guard found.isSuccess, let id = try InfluxCatalogDecoder.v2BucketID(found.data) else { return fallback }
            let mappings = try await connection.send(
                InfluxRequests.v2DBRPs(bucketID: id, organization: organization, credentials: connection.credentials)
            )
            guard mappings.isSuccess, let target = try InfluxCatalogDecoder.v2InfluxQLTarget(mappings.data) else {
                return fallback
            }
            lock.withLock { influxQLTargets[bucket] = target }
            return target
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return fallback
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

    var gridLanguage: InfluxQueryLanguage? {
        lock.withLock { server?.generation.gridLanguage }
    }

    // MARK: - Schema and grid statements

    func columns(of measurement: String) async throws -> [InfluxColumn] {
        let key = lock.withLock { SchemaKey(database: database, measurement: measurement) }
        if let cached = lock.withLock({ schemas[key] }) { return cached }
        return try await loadColumns(of: measurement)
    }

    func loadColumns(of measurement: String) async throws -> [InfluxColumn] {
        let (_, server) = try requireConnection()
        let key = lock.withLock { SchemaKey(database: database, measurement: measurement) }
        let columns: [InfluxColumn]
        switch server.generation {
        case .v3:
            columns = InfluxSchema.v3Columns(from: try await run(InfluxSchema.v3ColumnsStatement(measurement: measurement)))
        case .v2:
            let target = try await influxQLTarget()
            async let tags = run(InfluxSchema.influxQLTagKeysStatement(measurement: measurement, target: target))
            async let fields = run(InfluxSchema.influxQLFieldKeysStatement(measurement: measurement, target: target))
            columns = InfluxSchema.influxQLColumns(tagKeys: try await tags, fieldKeys: try await fields)
        }
        lock.withLock { schemas[key] = columns }
        return columns
    }

    func gridStatement(_ grid: InfluxGridQuery, hostKinds: [String: PluginColumnKind]) -> String? {
        let key = lock.withLock { SchemaKey(database: database, measurement: grid.measurement) }
        let fromHost = hostKinds.compactMapValues(Self.kind(of:))
        var kinds = fromHost
        if let schema = lock.withLock({ schemas[key] }) {
            kinds.merge(Self.kinds(of: schema)) { _, schema in schema }
        }
        let language = gridLanguage
        guard let statement = grid.statement(language: language ?? .influxQL, kinds: kinds, marked: language != nil)
        else { return nil }
        lock.withLock { gridQueries[statement] = RememberedGridQuery(query: grid, hostKinds: fromHost) }
        return statement
    }

    static func kinds(of schema: [InfluxColumn]) -> [String: InfluxColumnKind] {
        Dictionary(schema.map { ($0.name, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }

    private static func kind(of hostKind: PluginColumnKind) -> InfluxColumnKind? {
        switch hostKind {
        case .text: return .text
        case .integer, .decimal: return .number
        case .boolean: return .boolean
        case .other: return nil
        @unknown default: return nil
        }
    }

    static func columnInfo(name: String, typeName: String, role: InfluxColumn.Role?) -> PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: typeName,
            isNullable: role != .time,
            comment: role == .tag ? "tag" : nil,
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: nil,
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            classificationTypeName: InfluxTypeName.classificationName(for: typeName),
            columnCheck: nil
        )
    }
}

// The statements the driver built for its grid, so `execute` runs them knowing the measurement they read.
private struct RememberedGridQuery {
    let query: InfluxGridQuery
    let hostKinds: [String: InfluxColumnKind]
}

private struct GridQueryMemo {
    private var queries: [String: RememberedGridQuery] = [:]
    private var order: [String] = []
    private static let capacity = 64

    subscript(statement: String) -> RememberedGridQuery? {
        get { queries[statement] }
        set {
            guard let newValue else { return }
            if queries.updateValue(newValue, forKey: statement) == nil {
                order.append(statement)
            }
            if order.count > Self.capacity {
                queries.removeValue(forKey: order.removeFirst())
            }
        }
    }
}

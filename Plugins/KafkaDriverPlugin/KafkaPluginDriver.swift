import Foundation
import TableProPluginKit

/// The Kafka driver.
///
/// Topics are reported as external tables, which is how the host learns a table cannot be
/// edited: `TableType.externalTable` has `allowsRowEditing == false`, so the grid refuses a
/// cell edit up front with a real message instead of accepting one and failing at save time.
/// That matches Kafka, where a message is immutable once written and there is no update
/// primitive at all.
final class KafkaPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let cluster: KafkaCluster
    private let state = KafkaDriverState()
    private let anchors = KafkaAnchorStore()

    var capabilities: PluginCapabilities { [] }

    /// The config is read here and not retained. It carries the password, and nothing after
    /// this point needs it: the cluster holds only what it must to reconnect.
    init(config: DriverConnectionConfig) {
        let defaultPort = KafkaPlugin.defaultPort
        var endpoints: [KafkaEndpoint] = []
        if !config.host.isEmpty {
            endpoints.append(KafkaEndpoint(host: config.host, port: config.port > 0 ? config.port : defaultPort))
        }
        // Extra bootstrap servers are only meaningful when this client is dialling the cluster
        // itself. Behind a tunnel the host has already been rewritten to the single forwarded
        // endpoint and the others are unreachable, so the app clears the list.
        let extra = config.additionalFields[KafkaConnectionField.bootstrapServers] ?? ""
        for entry in extra.split(separator: ",") {
            if let endpoint = KafkaEndpoint.parse(String(entry), defaultPort: defaultPort) {
                endpoints.append(endpoint)
            }
        }
        if endpoints.isEmpty {
            endpoints.append(KafkaEndpoint(host: "127.0.0.1", port: defaultPort))
        }

        let mechanism = KafkaConnectionField.mechanism(from: config.additionalFields)
        cluster = KafkaCluster(
            bootstrap: endpoints,
            ssl: KafkaConnectionField.effectiveSSL(config.ssl, fields: config.additionalFields),
            credentials: KafkaCredentials(
                mechanism: mechanism,
                username: config.username,
                password: config.password
            ),
            routing: KafkaBrokerRouting.resolve(config.additionalFields[KafkaConnectionField.brokerRouting]),
            connectTimeoutSeconds: Int(config.additionalFields[KafkaConnectionField.connectTimeout] ?? "") ?? 10
        )
    }

    // MARK: - Lifecycle

    func connect() async throws {
        try await cluster.connect()
        let metadata = try await cluster.metadata(refresh: true)
        await state.setClusterId(metadata.clusterId)
    }

    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws {
        report(.openingConnection)
        try await cluster.connect()
        report(.authenticating)
        let metadata = try await cluster.metadata(refresh: true)
        await state.setClusterId(metadata.clusterId)
        report(.preparingSession)
    }

    func disconnect() {
        let cluster = cluster
        Task { await cluster.disconnect() }
    }

    /// The host's health monitor calls this every 30 seconds. A Metadata round trip is the
    /// cheapest request that actually proves the connection still works; there is no Kafka
    /// equivalent of `SELECT 1`, and the inherited default would send exactly that.
    func ping() async throws {
        _ = try await cluster.metadata(refresh: true)
    }

    var serverVersion: String? {
        get async { await state.clusterId.map { "Kafka cluster \($0)" } }
    }

    // MARK: - Schema

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    func fetchSchemas() async throws -> [String] { [] }
    func fetchExternalSchemaNames() async throws -> Set<String> { [] }
    func switchSchema(to schema: String) async throws {}

    /// A cluster has no databases. Reporting exactly one keeps the sidebar's container level
    /// honest rather than inventing a hierarchy Kafka does not have.
    func fetchDatabases() async throws -> [String] {
        [KafkaPlugin.singleDatabaseName]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let metadata = try await cluster.metadata()
        return PluginDatabaseMetadata(
            name: database,
            tableCount: metadata.topics.filter { !$0.isInternal }.count
        )
    }

    func switchDatabase(to database: String) async throws {}
    var currentDatabase: String? { KafkaPlugin.singleDatabaseName }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let metadata = try await cluster.metadata(refresh: true)
        return metadata.topics
            .filter { !$0.name.isEmpty }
            .sorted { $0.name < $1.name }
            .map { topic in
                PluginTableInfo(
                    name: topic.name,
                    // Internal topics are Kafka's own bookkeeping (__consumer_offsets and
                    // friends). Marking them system keeps them out of the way without hiding
                    // them from someone who needs to look.
                    type: topic.isInternal ? "system table" : "external table",
                    rowCount: nil
                )
            }
    }

    func fetchPartitions(table: String, schema: String?) async throws -> [PluginTableInfo] {
        let metadata = try await cluster.metadata(topics: [table])
        let topic = try metadata.requireTopic(named: table)
        return topic.partitions.sorted { $0.index < $1.index }.map { partition in
            PluginTableInfo(name: "\(table)-\(partition.index)", type: "partition", rowCount: nil)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        KafkaMessageFlattener.columns(for: [])
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] { [] }
    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] { [] }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let metadata = try await cluster.metadata(topics: [table])
        let topic = try metadata.requireTopic(named: table)
        var lines = ["Topic: \(topic.name)"]
        if !topic.topicId.isZero { lines.append("Id: \(topic.topicId.uuidString)") }
        lines.append("Internal: \(topic.isInternal ? "yes" : "no")")
        lines.append("Partitions: \(topic.partitions.count)")
        for partition in topic.partitions.sorted(by: { $0.index < $1.index }) {
            lines.append(
                "  partition \(partition.index)  leader \(partition.leader)"
                    + "  replicas [\(partition.replicas.map(String.init).joined(separator: ","))]"
                    + "  in-sync [\(partition.inSyncReplicas.map(String.init).joined(separator: ","))]"
            )
        }
        return lines.joined(separator: "\n")
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let metadata = try await cluster.metadata(topics: [table])
        let topic = try metadata.requireTopic(named: table)
        let bounds = try await KafkaOffsetsRequest.bounds(
            topic: table,
            partitions: topic.partitions.map(\.index),
            cluster: cluster
        )
        let total = bounds.reduce(Int64(0)) { $0 + $1.messageCount }
        return PluginTableMetadata(tableName: table, rowCount: total)
    }

    /// Retention makes any count a snapshot rather than a fact, so this is deliberately the
    /// approximate hook rather than the exact one.
    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await fetchTableMetadata(table: table, schema: schema).rowCount.map(Int.init)
    }

    // MARK: - Query execution

    func execute(query: String) async throws -> PluginQueryResult {
        try await run(KafkaQL.parse(query))
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        var statement = try KafkaQL.parse(query)
        if let rowCap, case .consume(var consume) = statement {
            consume.limit = min(consume.limit, rowCap)
            statement = .consume(consume)
        }
        return try await run(statement)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await execute(query: query)
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        try await executeUserQuery(query: query, rowCap: rowCap, parameters: nil)
    }

    /// `Task.cancel()` propagates through every await in this driver, so there is nothing
    /// separate to cancel: no request blocks in C, and the connection closes itself from the
    /// cancellation handler around its one in-flight write.
    func cancelQuery() throws {}

    func applyQueryTimeout(_ seconds: Int) async throws {}

    var supportsTransactions: Bool { false }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    var parameterStyle: ParameterStyle { .questionMark }
    var requiresBackslashEscapingInLiterals: Bool { false }

    func quoteIdentifier(_ name: String) -> String { KafkaQL.quote(name) }

    func escapeStringLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Browse

    /// The host asks for a page as an integer limit and offset. Kafka cannot skip N messages
    /// server-side, so the driver does the skipping after the merge, and every page after the
    /// first reads the anchor the first one resolved.
    ///
    /// That anchor is what keeps paging honest. Re-deriving `NEWEST` on page two measures it
    /// against a tail that has moved, so rows from page one reappear and older ones are never
    /// shown. Page one records where it started and later pages name it explicitly.
    func buildBrowseQuery(
        table: String,
        schema: String?,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let page = max(1, limit)
        guard offset > 0 else {
            anchors.clear(table)
            return "CONSUME \(KafkaQL.quote(table)) FROM NEWEST LIMIT \(page)"
        }
        guard let anchor = anchors.anchor(for: table), !anchor.isEmpty else {
            // Nothing was recorded, so there is no window to continue. Re-deriving is worse
            // than nothing here, but it is what the host asked for.
            return "CONSUME \(KafkaQL.quote(table)) FROM NEWEST LIMIT \(page) SKIP \(offset)"
        }
        let pairs = anchor.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        return "CONSUME \(KafkaQL.quote(table)) FROM ANCHOR (\(pairs)) LIMIT \(page) SKIP \(offset)"
    }

    /// Kafka has no server-side WHERE over a log. Returning nil rather than a filtered query
    /// keeps the host from believing a filter was applied; the browse query is used instead.
    func buildFilteredQuery(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        buildBrowseQuery(
            table: table,
            schema: schema,
            sortColumns: sortColumns,
            columns: columns,
            limit: limit,
            offset: offset
        )
    }

    /// Declining every statement is what stops the grid's Save from silently doing nothing.
    /// Paired with the external-table type on each topic, the refusal reaches the user before
    /// they type rather than after.
    func generateStatements(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        nil
    }

    // MARK: - Result building

    /// Every result this driver returns is built from `PluginColumnInfo`, because the column
    /// type is what decides how the host formats a cell. Passing the same columns as
    /// `columnMeta` keeps the type the flattener chose attached to the column it belongs to.
    private static func makeResult(
        columns: [PluginColumnInfo],
        rows: [[PluginCellValue]],
        rowsAffected: Int,
        isTruncated: Bool = false
    ) -> PluginQueryResult {
        PluginQueryResult(
            columns: columns.map(\.name),
            columnTypeNames: columns.map(\.dataType),
            rows: rows,
            rowsAffected: rowsAffected,
            executionTime: 0,
            isTruncated: isTruncated,
            columnMeta: columns
        )
    }

    // MARK: - Statement dispatch

    private func run(_ statement: KafkaStatement) async throws -> PluginQueryResult {
        switch statement {
        case .consume(let query):
            return try await runConsume(query)
        case .produce(let query):
            return try await runProduce(query)
        case .showTopics:
            return try await runShowTopics()
        case .showBrokers:
            return try await runShowBrokers()
        case .showGroups:
            return try await runShowGroups()
        case .describeGroup(let group):
            return try await runDescribeGroup(group)
        case .describeTopic(let topic):
            return try await runDescribeTopic(topic)
        case .showCluster:
            return try await runShowCluster()
        }
    }

    private func runConsume(_ query: KafkaConsumeQuery) async throws -> PluginQueryResult {
        let page = try await KafkaBrowseEngine.consume(query, cluster: cluster)
        // Only a fresh scan sets the anchor. A continuation page was handed one already, and
        // overwriting it with its own start would walk the window forward a page at a time.
        if case .resolved = query.start {} else {
            anchors.record(page.anchor, for: query.topic)
        }
        let kinds = KafkaMessageFlattener.payloadKinds(for: page.records)
        return Self.makeResult(
            columns: KafkaMessageFlattener.columns(kinds: kinds),
            rows: KafkaMessageFlattener.rows(for: page.records, kinds: kinds),
            rowsAffected: 0,
            isTruncated: page.truncated
        )
    }

    private func runProduce(_ query: KafkaProduceQuery) async throws -> PluginQueryResult {
        let metadata = try await cluster.metadata(topics: [query.topic])
        let topic = try metadata.requireTopic(named: query.topic)
        let partitions = topic.partitions.map(\.index).sorted()
        guard !partitions.isEmpty else { throw KafkaError.unknownTopic(query.topic) }

        let partition: Int32
        if let requested = query.partition {
            guard partitions.contains(requested) else {
                throw KafkaError.producedToUnknownPartition(topic: query.topic, partition: requested)
            }
            partition = requested
        } else if let key = query.key {
            // Kafka's own default partitioner hashes the key with murmur2, and matching it
            // means a message produced here lands where the rest of that key's messages are.
            partition = partitions[Int(KafkaPartitioner.partition(forKey: Data(key.utf8), count: partitions.count))]
        } else {
            partition = partitions[0]
        }

        let result = try await KafkaProduceRequest.produce(
            topic: query.topic,
            partition: partition,
            key: query.key.map { Data($0.utf8) },
            value: query.value.map { Data($0.utf8) },
            headers: query.headers,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            cluster: cluster
        )
        return Self.makeResult(
            columns: [
                PluginColumnInfo(name: "topic", dataType: "TEXT", isNullable: false),
                PluginColumnInfo(name: "partition", dataType: "INTEGER", isNullable: false),
                PluginColumnInfo(name: "offset", dataType: "BIGINT", isNullable: false)
            ],
            rows: [[.text(query.topic), .text(String(result.partition)), .text(String(result.baseOffset))]],
            rowsAffected: 1
        )
    }

    private func runShowTopics() async throws -> PluginQueryResult {
        let metadata = try await cluster.metadata(refresh: true)
        let rows = metadata.topics
            .sorted { $0.name < $1.name }
            .map { topic -> [PluginCellValue] in
                [
                    .text(topic.name),
                    .text(String(topic.partitions.count)),
                    .text(String(topic.partitions.first?.replicas.count ?? 0)),
                    .text(topic.isInternal ? "yes" : "no")
                ]
            }
        return Self.makeResult(
            columns: [
                PluginColumnInfo(name: "topic", dataType: "TEXT", isNullable: false),
                PluginColumnInfo(name: "partitions", dataType: "INTEGER", isNullable: false),
                PluginColumnInfo(name: "replication_factor", dataType: "INTEGER", isNullable: false),
                PluginColumnInfo(name: "internal", dataType: "TEXT", isNullable: false)
            ],
            rows: rows,
            rowsAffected: 0
        )
    }

    private func runShowBrokers() async throws -> PluginQueryResult {
        let metadata = try await cluster.metadata(refresh: true)
        let rows = metadata.brokers.sorted { $0.nodeId < $1.nodeId }.map { broker -> [PluginCellValue] in
            [
                .text(String(broker.nodeId)),
                .text(broker.endpoint.host),
                .text(String(broker.endpoint.port)),
                broker.rack.map { PluginCellValue.text($0) } ?? .null,
                .text(broker.nodeId == metadata.controllerId ? "yes" : "no")
            ]
        }
        return Self.makeResult(
            columns: [
                PluginColumnInfo(name: "node_id", dataType: "INTEGER", isNullable: false),
                PluginColumnInfo(name: "host", dataType: "TEXT", isNullable: false),
                PluginColumnInfo(name: "port", dataType: "INTEGER", isNullable: false),
                PluginColumnInfo(name: "rack", dataType: "TEXT", isNullable: true),
                PluginColumnInfo(name: "controller", dataType: "TEXT", isNullable: false)
            ],
            rows: rows,
            rowsAffected: 0
        )
    }

    private func runShowGroups() async throws -> PluginQueryResult {
        let groups = try await KafkaGroupsRequest.listGroups(cluster: cluster)
        let rows = groups.sorted { $0.groupId < $1.groupId }.map { group -> [PluginCellValue] in
            [.text(group.groupId), .text(group.state), .text(group.protocolType)]
        }
        return Self.makeResult(
            columns: [
                PluginColumnInfo(name: "group", dataType: "TEXT", isNullable: false),
                PluginColumnInfo(name: "state", dataType: "TEXT", isNullable: false),
                PluginColumnInfo(name: "protocol_type", dataType: "TEXT", isNullable: false)
            ],
            rows: rows,
            rowsAffected: 0
        )
    }

    /// A group's lag, per partition. This is the number a Kafka debugging session is usually
    /// after: how far behind the consumers are, and on which partition.
    private func runDescribeGroup(_ group: String) async throws -> PluginQueryResult {
        let committed = try await KafkaGroupsRequest.fetchCommittedOffsets(group: group, cluster: cluster)
        var rows: [[PluginCellValue]] = []
        let byTopic = Dictionary(grouping: committed, by: \.topic)

        for (topic, offsets) in byTopic.sorted(by: { $0.key < $1.key }) {
            let latest = try await KafkaOffsetsRequest.listOffsets(
                topic: topic,
                partitions: offsets.map(\.partition),
                timestamp: KafkaOffsetsRequest.latestTimestamp,
                cluster: cluster
            )
            for offset in offsets.sorted(by: { $0.partition < $1.partition }) {
                let end = latest[offset.partition] ?? 0
                // A group that never committed a partition reports -1, and calling that a lag
                // of `end + 1` would be a fabricated number.
                let lag: PluginCellValue = offset.committedOffset >= 0
                    ? .text(String(max(0, end - offset.committedOffset)))
                    : .null
                rows.append([
                    .text(topic),
                    .text(String(offset.partition)),
                    offset.committedOffset >= 0 ? .text(String(offset.committedOffset)) : .null,
                    .text(String(end)),
                    lag
                ])
            }
        }
        return Self.makeResult(
            columns: [
                PluginColumnInfo(name: "topic", dataType: "TEXT", isNullable: false),
                PluginColumnInfo(name: "partition", dataType: "INTEGER", isNullable: false),
                PluginColumnInfo(name: "committed_offset", dataType: "BIGINT", isNullable: true),
                PluginColumnInfo(name: "end_offset", dataType: "BIGINT", isNullable: false),
                PluginColumnInfo(name: "lag", dataType: "BIGINT", isNullable: true)
            ],
            rows: rows,
            rowsAffected: 0
        )
    }

    private func runDescribeTopic(_ topic: String) async throws -> PluginQueryResult {
        let metadata = try await cluster.metadata(topics: [topic])
        let found = try metadata.requireTopic(named: topic)
        let bounds = try await KafkaOffsetsRequest.bounds(
            topic: topic,
            partitions: found.partitions.map(\.index),
            cluster: cluster
        )
        let boundsByPartition = Dictionary(uniqueKeysWithValues: bounds.map { ($0.partition, $0) })
        let rows = found.partitions.sorted { $0.index < $1.index }.map { partition -> [PluginCellValue] in
            let bound = boundsByPartition[partition.index]
            return [
                .text(String(partition.index)),
                .text(String(partition.leader)),
                .text(partition.replicas.map(String.init).joined(separator: ",")),
                .text(partition.inSyncReplicas.map(String.init).joined(separator: ",")),
                .text(String(bound?.earliest ?? 0)),
                .text(String(bound?.latest ?? 0)),
                .text(String(bound?.messageCount ?? 0))
            ]
        }
        return Self.makeResult(
            columns: [
                PluginColumnInfo(name: "partition", dataType: "INTEGER", isNullable: false),
                PluginColumnInfo(name: "leader", dataType: "INTEGER", isNullable: false),
                PluginColumnInfo(name: "replicas", dataType: "TEXT", isNullable: false),
                PluginColumnInfo(name: "in_sync_replicas", dataType: "TEXT", isNullable: false),
                PluginColumnInfo(name: "earliest_offset", dataType: "BIGINT", isNullable: false),
                PluginColumnInfo(name: "latest_offset", dataType: "BIGINT", isNullable: false),
                PluginColumnInfo(name: "messages", dataType: "BIGINT", isNullable: false)
            ],
            rows: rows,
            rowsAffected: 0
        )
    }

    private func runShowCluster() async throws -> PluginQueryResult {
        let metadata = try await cluster.metadata(refresh: true)
        let rows: [[PluginCellValue]] = [
            [.text("cluster_id"), metadata.clusterId.map { PluginCellValue.text($0) } ?? .null],
            [.text("controller"), .text(String(metadata.controllerId))],
            [.text("brokers"), .text(String(metadata.brokers.count))],
            [.text("topics"), .text(String(metadata.topics.filter { !$0.isInternal }.count))],
            [.text("bootstrap"), .text(await cluster.bootstrapEndpointDescription())]
        ]
        return Self.makeResult(
            columns: [
                PluginColumnInfo(name: "property", dataType: "TEXT", isNullable: false),
                PluginColumnInfo(name: "value", dataType: "TEXT", isNullable: true)
            ],
            rows: rows,
            rowsAffected: 0
        )
    }
}

/// Where each topic's current browse window starts, so page two continues page one.
///
/// A plain lock rather than an actor: `buildBrowseQuery` is a synchronous protocol requirement
/// and cannot await.
private final class KafkaAnchorStore: @unchecked Sendable {
    private var anchors: [String: [Int32: Int64]] = [:]
    private let lock = NSLock()

    func record(_ anchor: [Int32: Int64], for table: String) {
        lock.lock()
        defer { lock.unlock() }
        anchors[table] = anchor
    }

    func anchor(for table: String) -> [Int32: Int64]? {
        lock.lock()
        defer { lock.unlock() }
        return anchors[table]
    }

    func clear(_ table: String) {
        lock.lock()
        defer { lock.unlock() }
        anchors[table] = nil
    }
}

private actor KafkaDriverState {
    private(set) var clusterId: String?

    func setClusterId(_ value: String?) {
        clusterId = value
    }
}

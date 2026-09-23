import Foundation
import TableProPluginKit

extension DynamoDBPluginDriver {
    static let columnSampleSize = 100

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        try await run(isUserOperation: false) { session in
            var names: [String] = []
            var start: String?
            repeat {
                try session.checkDeadline()
                var body: [String: DynamoDBJSON] = ["Limit": .number("100")]
                if let start { body["ExclusiveStartTableName"] = .string(start) }
                let response = try await session.client.send(.listTables, body)
                names += (response["TableNames"]?.arrayValue ?? []).compactMap(\.stringValue)
                start = response["LastEvaluatedTableName"]?.stringValue
            } while start != nil
            return names
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { PluginTableInfo(name: $0, type: "TABLE") }
        }
    }

    /// The key attributes of the table and its indexes, typed as the table declares them, then the
    /// attributes found in one sampled page. A DynamoDB table declares nothing else.
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await run(isUserOperation: false) { session in
            let description = try await self.tableSchema(table, session: session, refresh: true)
            let sample = try await self.sample(table: table, session: session)
            let observed = DynamoDBItemTable(items: sample, schema: description)
            self.catalog.mergeColumnTypes(observed.observedTypes, for: table, in: session.scope)
            let indexKeys = description.indexes.flatMap(\.keys.attributes)
            var columns = observed.columns
            for key in indexKeys where !columns.contains(key) {
                columns.insert(key, at: min(description.keys.attributes.count, columns.count))
            }
            return columns.map { name in
                let type = description.keyType(of: name) ?? observed.observedTypes[name] ?? .string
                return Self.columnInfo(name: name, type: type, schema: description)
            }
        }
    }

    static func columnInfo(name: String, type: DynamoDBAttributeType, schema: DynamoDBTableSchema) -> PluginColumnInfo {
        let isTableKey = schema.keys.attributes.contains(name)
        var roles: [String] = []
        if schema.keys.partition.contains(name) { roles.append(String(localized: "Partition key")) }
        if schema.keys.sort.contains(name) { roles.append(String(localized: "Sort key")) }
        for index in schema.indexes where index.keys.attributes.contains(name) {
            roles.append(String(format: String(localized: "Key of %@"), index.name))
        }
        return PluginColumnInfo(
            name: name,
            dataType: type.displayName,
            isNullable: !isTableKey,
            isPrimaryKey: isTableKey,
            defaultValue: nil,
            extra: roles.isEmpty ? nil : roles.joined(separator: ", "),
            charset: nil,
            collation: nil,
            comment: nil,
            identityKind: nil,
            isGenerated: false,
            allowedValues: nil,
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: nil,
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            classificationTypeName: type.classificationName
        )
    }

    /// Columns for autocomplete, from the tables already described, with no request at all. The
    /// app asks for every table on connect, and answering by sampling each one read up to 300
    /// tables in the background.
    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        guard let scope else { return [:] }
        var result: [String: [PluginColumnInfo]] = [:]
        for description in catalog.cachedSchemas(in: scope) {
            let observed = catalog.columnTypes(for: description.name, in: scope)
            var names = description.keys.attributes
            names += description.indexes.flatMap(\.keys.attributes).filter { !names.contains($0) }
            names += observed.keys.sorted().filter { !names.contains($0) }
            result[description.name] = names.map { name in
                Self.columnInfo(
                    name: name, type: description.keyType(of: name) ?? observed[name] ?? .string, schema: description
                )
            }
        }
        return result
    }

    func sample(table: String, session: Session) async throws -> [DynamoDBItem] {
        let response = try await session.client.send(
            .scan, ["TableName": .string(table), "Limit": .number(String(Self.columnSampleSize))]
        )
        return try (response["Items"]?.arrayValue ?? []).map(DynamoDBItem.init(wireItem:))
    }

    /// Nested attribute paths for the filter bar and autocomplete, such as `address.city`.
    func sampleFieldPaths(table: String, schema: String?, limit: Int) async throws -> [PluginFieldPath] {
        try await run(isUserOperation: false) { session in
            let response = try await session.client.send(
                .scan, ["TableName": .string(table), "Limit": .number(String(min(max(limit, 1), Self.columnSampleSize)))]
            )
            let items = try (response["Items"]?.arrayValue ?? []).map(DynamoDBItem.init(wireItem:))
            return DynamoDBFieldPaths.collect(from: items)
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        try await run(isUserOperation: false) { session in
            let description = try await self.tableSchema(table, session: session)
            var indexes = [
                PluginIndexInfo(
                    name: "PRIMARY", columns: description.keys.attributes,
                    isUnique: true, isPrimary: true, type: DynamoDBIndexTypeName.primary
                )
            ]
            for index in description.indexes {
                let kind = index.kind == .global ? DynamoDBIndexTypeName.global : DynamoDBIndexTypeName.local
                var type = "\(kind) \(index.projection.displayName)"
                if let status = index.status, status != "ACTIVE" { type += " \(status)" }
                if index.isBackfilling { type += " BACKFILLING" }
                indexes.append(PluginIndexInfo(
                    name: index.name,
                    columns: index.keys.attributes,
                    isUnique: false,
                    isPrimary: false,
                    type: type,
                    columnPrefixes: nil,
                    whereClause: nil,
                    expressions: nil,
                    includedColumns: index.projection.nonKeyAttributes.isEmpty ? nil : index.projection.nonKeyAttributes,
                    ddlMethodAndKeys: nil,
                    ddlWhereClause: nil
                ))
            }
            return indexes
        }
    }

    /// DynamoDB's own item count, refreshed by AWS about every six hours.
    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await run(isUserOperation: false) { session in
            let description = try await self.tableSchema(table, session: session, refresh: true)
            return description.itemCount.map { Int(clamping: $0) }
        }
    }

    func fetchFilteredRowCount(table: String, queryFilters: [PluginQueryFilter], logicMode: String) async throws -> Int? {
        nil
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) async throws -> Int? {
        try await fetchExactRowCount(
            table: table, schema: schema,
            queryFilters: filters.map { PluginQueryFilter(column: $0.column, op: $0.op, value: $0.value) },
            logicMode: logicMode
        )
    }

    /// Count Exactly: the same read the grid runs, answered with `Select: COUNT` so no item comes
    /// back, and paged to the end. It is billed like reading every item it counts.
    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        try await run(boundedByQueryTimeout: false) { session in
            let description = try await self.tableSchema(table, session: session)
            let knownAttributes = self.catalog.columnTypes(for: table, in: session.scope).keys.sorted()
            let request = DynamoDBBrowseRequest(
                table: table, queryFilters: queryFilters, logicMode: logicMode,
                columns: knownAttributes, columnKinds: [:]
            )
            let plan = try DynamoDBAccessPlanner(schema: description).plan(request, order: [])
            return try await self.count(plan, schema: description, session: session)
        }
    }

    private func count(_ plan: DynamoDBReadPlan, schema: DynamoDBTableSchema, session: Session) async throws -> Int {
        guard plan.access == .query || plan.access == .scan, plan.clientPredicates.isEmpty else {
            var total = 0
            _ = try await readPlan(
                plan, schema: schema, offset: 0, limit: Int.max,
                fingerprint: "count:\(UUID().uuidString)", session: session
            ) { _ in
                total += 1
                return true
            }
            return total
        }
        var total = 0
        let operation: DynamoDBOperation = plan.access == .query ? .query : .scan
        for request in plan.requests {
            var startKey: DynamoDBJSON?
            repeat {
                try session.checkDeadline()
                var body = request
                body["Select"] = .string("COUNT")
                if let startKey { body["ExclusiveStartKey"] = startKey }
                let response = try await session.client.send(operation, body)
                total += response["Count"]?.intValue ?? 0
                startKey = response["LastEvaluatedKey"]
            } while startKey != nil
        }
        return total
    }

    // MARK: - DDL and metadata

    /// Statements that recreate the table: its `CreateTable` request, then Time to Live and
    /// point-in-time recovery when they are on. Settings DynamoDB Local does not have are left out.
    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        try await run(isUserOperation: false) { session in
            let description = try await self.tableSchema(table, session: session)
            var statements = [
                DynamoDBStatement.apiCall(
                    DynamoDBAPICall(operation: .createTable, body: DynamoDBTableDefinition.createTableRequest(description)),
                    window: DynamoDBReadWindow()
                ).prettyText
            ]
            if let ttl = try? await session.client.send(.describeTimeToLive, ["TableName": .string(table)]),
               ttl["TimeToLiveDescription"]?["TimeToLiveStatus"]?.stringValue == "ENABLED",
               let attribute = ttl["TimeToLiveDescription"]?["AttributeName"]?.stringValue {
                statements.append(DynamoDBStatement.apiCall(
                    DynamoDBAPICall(operation: .updateTimeToLive, body: .object([
                        "TableName": .string(table),
                        "TimeToLiveSpecification": .object(["Enabled": .bool(true), "AttributeName": .string(attribute)])
                    ])),
                    window: DynamoDBReadWindow()
                ).prettyText)
            }
            if let backups = try? await session.client.send(.describeContinuousBackups, ["TableName": .string(table)]),
               backups["ContinuousBackupsDescription"]?["PointInTimeRecoveryDescription"]?["PointInTimeRecoveryStatus"]?
                   .stringValue == "ENABLED" {
                statements.append(DynamoDBStatement.apiCall(
                    DynamoDBAPICall(operation: .updateContinuousBackups, body: .object([
                        "TableName": .string(table),
                        "PointInTimeRecoverySpecification": .object(["PointInTimeRecoveryEnabled": .bool(true)])
                    ])),
                    window: DynamoDBReadWindow()
                ).prettyText)
            }
            return statements.joined(separator: ";\n\n") + ";"
        }
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        try await run(isUserOperation: false) { session in
            let description = try await self.tableSchema(table, session: session, refresh: true)
            return PluginTableMetadata(
                tableName: description.name,
                dataSize: description.sizeBytes,
                indexSize: description.indexes.compactMap(\.sizeBytes).reduce(0, +),
                totalSize: description.sizeBytes,
                rowCount: description.itemCount,
                comment: DynamoDBTableDefinition.summary(description),
                engine: "DynamoDB",
                createTime: description.createdAt
            )
        }
    }
}

extension DynamoDBStatement {
    var prettyText: String {
        guard case .apiCall(let call, _) = self else { return text }
        return "\(call.operation.rawValue) \(call.body.serialized(pretty: true))"
    }
}

/// The `type` a DynamoDB index reports in the Structure tab. It comes back on an edited row, which
/// is how a refusal tells a local index and the primary key from a global index.
enum DynamoDBIndexTypeName {
    static let primary = "PRIMARY KEY"
    static let global = "GLOBAL"
    static let local = "LOCAL"
}

/// Nested attribute paths for the filter bar and autocomplete, through maps only. A path through a
/// list names no element DynamoDB can compare, so `items.sku` over a list of maps would filter every
/// item out.
enum DynamoDBFieldPaths {
    static let maximumDepth = 4

    static func collect(from items: [DynamoDBItem]) -> [PluginFieldPath] {
        var found: [String: PluginFieldPath] = [:]
        for item in items {
            for (name, value) in item {
                visit(value, path: name, depth: 1, into: &found)
            }
        }
        return found.values.sorted { $0.path < $1.path }
    }

    private static func visit(
        _ value: DynamoDBAttributeValue,
        path: String,
        depth: Int,
        into found: inout [String: PluginFieldPath]
    ) {
        if found[path] == nil {
            found[path] = PluginFieldPath(path: path, typeName: value.type.displayName, depth: depth)
        }
        guard depth < maximumDepth, case .map(let entries) = value else { return }
        for (key, nested) in entries {
            visit(nested, path: "\(path).\(key)", depth: depth + 1, into: &found)
        }
    }
}

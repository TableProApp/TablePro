import Foundation
import TableProPluginKit

extension DynamoDBPluginDriver {
    /// Runs one DynamoDB action from the editor or from a statement the driver built.
    func callAPI(_ call: DynamoDBAPICall, session: Session) async throws -> PluginQueryResult {
        let started = Date()
        guard var body = call.body.objectValue else {
            throw DynamoDBError.invalidStatement(String(localized: "The request must be a JSON object"))
        }
        let table = body["TableName"]?.stringValue
        switch call.operation {
        case .updateTable:
            if let table { body = try await completingAttributeDefinitions(body, table: table, session: session) }
        case .updateTimeToLive:
            if let table { body = try await completingTimeToLive(body, table: table, session: session) }
        case .transactWriteItems, .executeTransaction:
            if body["ClientRequestToken"] == nil {
                body["ClientRequestToken"] = .string(UUID().uuidString)
            }
        default:
            break
        }

        switch call.operation {
        case .batchWriteItem:
            return try await batchWrite(body, session: session, started: started)
        case .batchGetItem:
            let tables = body["RequestItems"]?.objectValue?.keys.sorted() ?? []
            var items: [DynamoDBItem] = []
            for name in tables {
                let request: [String: DynamoDBJSON] = ["RequestItems": .object([name: body["RequestItems"]?[name] ?? .null])]
                items += try await batchGet(body: request, table: name, session: session)
            }
            return Self.queryResult(
                items: items, schema: nil, preferredColumns: [], includeAllKeys: false,
                started: started, isTruncated: false, statusMessage: nil
            )
        case .batchExecuteStatement:
            defer { catalog.forgetReadPositions(in: session.scope) }
            return try await batchExecute(body, session: session, started: started)
        default:
            break
        }

        let response = try await session.client.send(call.operation, body)
        if !call.operation.isRead {
            if let table {
                catalog.forgetReadPositions(table: table, in: session.scope)
            } else {
                catalog.forgetReadPositions(in: session.scope)
            }
        }
        if call.operation.changesCatalog || call.operation == .updateTimeToLive || call.operation == .updateContinuousBackups,
           let table {
            catalog.invalidate(table: table, in: session.scope)
        }
        return try present(response, operation: call.operation, started: started, session: session, table: table)
    }

    private func present(
        _ response: DynamoDBJSON,
        operation: DynamoDBOperation,
        started: Date,
        session: Session,
        table: String?
    ) throws -> PluginQueryResult {
        switch operation {
        case .getItem:
            let items = try response["Item"].map { [try DynamoDBItem(wireItem: $0)] } ?? []
            return Self.queryResult(
                items: items, schema: table.flatMap { catalog.schema(for: $0, in: session.scope) },
                preferredColumns: [], includeAllKeys: false, started: started, isTruncated: false, statusMessage: nil
            )
        case .transactGetItems:
            let items = try (response["Responses"]?.arrayValue ?? []).compactMap { entry in
                try entry["Item"].map(DynamoDBItem.init(wireItem:))
            }
            return Self.queryResult(
                items: items, schema: nil, preferredColumns: [], includeAllKeys: false,
                started: started, isTruncated: false, statusMessage: nil
            )
        case .executeTransaction:
            let items = try (response["Responses"]?.arrayValue ?? []).compactMap { entry in
                try entry["Item"].map(DynamoDBItem.init(wireItem:))
            }
            guard !items.isEmpty else {
                return Self.messageResult(String(localized: "The transaction was applied"), started: started)
            }
            return Self.queryResult(
                items: items, schema: nil, preferredColumns: [], includeAllKeys: false,
                started: started, isTruncated: false, statusMessage: nil
            )
        case .listTables:
            let names = (response["TableNames"]?.arrayValue ?? []).compactMap(\.stringValue)
            return PluginQueryResult(
                columns: ["TableName"], columnTypeNames: ["String"], rows: names.map { [.text($0)] },
                rowsAffected: 0, timing: PluginQueryTiming(total: Date().timeIntervalSince(started)),
                statusMessage: response["LastEvaluatedTableName"] != nil
                    ? String(localized: "More tables follow. Pass LastEvaluatedTableName as ExclusiveStartTableName.")
                    : nil
            )
        case .putItem, .updateItem, .deleteItem:
            let attributes = try response["Attributes"].map { [try DynamoDBItem(wireItem: $0)] } ?? []
            guard attributes.isEmpty else {
                return Self.queryResult(
                    items: attributes, schema: nil, preferredColumns: [], includeAllKeys: false,
                    started: started, isTruncated: false, statusMessage: nil, rowsAffected: 1
                )
            }
            return Self.messageResult(
                String(format: String(localized: "%@ succeeded"), operation.rawValue), started: started, rowsAffected: 1
            )
        case .transactWriteItems:
            return Self.messageResult(String(localized: "The transaction was applied"), started: started)
        case .createTable, .updateTable, .deleteTable:
            let status = response["TableDescription"]?["TableStatus"]?.stringValue
            let message = status.map { String(format: String(localized: "%1$@ accepted. Table status: %2$@"), operation.rawValue, $0) }
            return Self.responseResult(response, started: started, statusMessage: message)
        default:
            return Self.responseResult(response, started: started, statusMessage: nil)
        }
    }

    // MARK: - Batches

    /// BatchWriteItem applies what it can and returns the rest as `UnprocessedItems`, inside an HTTP
    /// 200. The rest is sent again with backoff; whatever is still left is reported as a failure,
    /// never as success.
    private func batchWrite(_ body: [String: DynamoDBJSON], session: Session, started: Date) async throws -> PluginQueryResult {
        let total = (body["RequestItems"]?.objectValue ?? [:]).values.reduce(0) { $0 + ($1.arrayValue?.count ?? 0) }
        defer {
            for name in (body["RequestItems"]?.objectValue ?? [:]).keys {
                catalog.forgetReadPositions(table: name, in: session.scope)
            }
        }
        var pending = body["RequestItems"]
        var attempt = 0
        while let requestItems = pending, requestItems.objectValue?.isEmpty == false {
            let response = try await session.client.send(.batchWriteItem, ["RequestItems": requestItems])
            pending = response["UnprocessedItems"]
            let left = (pending?.objectValue ?? [:]).values.reduce(0) { $0 + ($1.arrayValue?.count ?? 0) }
            guard left > 0 else { break }
            attempt += 1
            guard attempt < 10 else {
                throw DynamoDBError.partialBatch(
                    applied: total - left, total: total,
                    failures: [String(format: String(localized: "%d requests were not processed after 10 attempts"), left)]
                )
            }
            try await session.client.backOff(afterAttempt: attempt)
        }
        return Self.messageResult(
            String(format: String(localized: "%d requests applied"), total), started: started, rowsAffected: total
        )
    }

    /// BatchExecuteStatement answers each statement on its own inside an HTTP 200, so a statement
    /// that failed is found in the response, not in the status.
    private func batchExecute(_ body: [String: DynamoDBJSON], session: Session, started: Date) async throws -> PluginQueryResult {
        let response = try await session.client.send(.batchExecuteStatement, body)
        let responses = response["Responses"]?.arrayValue ?? []
        let failures = responses.enumerated().compactMap { index, entry -> String? in
            guard let error = entry["Error"] else { return nil }
            let code = error["Code"]?.stringValue ?? "Error"
            let message = error["Message"]?.stringValue ?? ""
            return String(format: String(localized: "Statement %1$d: %2$@ %3$@"), index + 1, code, message)
        }
        guard failures.isEmpty else {
            throw DynamoDBError.partialBatch(applied: responses.count - failures.count, total: responses.count, failures: failures)
        }
        let items = try responses.compactMap { try $0["Item"].map(DynamoDBItem.init(wireItem:)) }
        guard items.isEmpty else {
            return Self.queryResult(
                items: items, schema: nil, preferredColumns: [], includeAllKeys: false,
                started: started, isTruncated: false, statusMessage: nil
            )
        }
        return Self.messageResult(
            String(format: String(localized: "%d statements applied"), responses.count),
            started: started, rowsAffected: responses.count
        )
    }

    // MARK: - Request completion

    /// An UpdateTable that creates a global secondary index has to declare the type of each key
    /// attribute the table does not already declare. The Structure tab's index editor has no type
    /// to give, so a missing declaration is filled from the table and from the attribute's type in
    /// the items, and a String when nothing says otherwise.
    func completingAttributeDefinitions(
        _ body: [String: DynamoDBJSON],
        table: String,
        session: Session
    ) async throws -> [String: DynamoDBJSON] {
        let creates = (body["GlobalSecondaryIndexUpdates"]?.arrayValue ?? []).compactMap { $0["Create"] }
        guard !creates.isEmpty else { return body }
        var declared = Set((body["AttributeDefinitions"]?.arrayValue ?? []).compactMap { $0["AttributeName"]?.stringValue })
        var definitions = body["AttributeDefinitions"]?.arrayValue ?? []
        let schema = try await tableSchema(table, session: session)
        var observed = catalog.columnTypes(for: table, in: session.scope)
        let needed = creates.flatMap { ($0["KeySchema"]?.arrayValue ?? []).compactMap { $0["AttributeName"]?.stringValue } }
        if needed.contains(where: { schema.keyType(of: $0) == nil && observed[$0] == nil }) {
            observed.merge(try await sampleTypes(table: table, schema: schema, session: session)) { current, _ in current }
        }
        for attribute in needed where !declared.contains(attribute) {
            let known = schema.keyType(of: attribute) ?? observed[attribute]
            guard let type = known, type.isKeyType else {
                throw DynamoDBError.invalidStatement(String(format: String(
                    localized: "No item read so far holds \"%@\" as a key type. Create this index from the editor with its AttributeDefinitions."
                ), attribute))
            }
            definitions.append(.object([
                "AttributeName": .string(attribute),
                "AttributeType": .string(type.rawValue)
            ]))
            declared.insert(attribute)
        }
        var completed = body
        completed["AttributeDefinitions"] = .array(definitions)
        if !schema.isOnDemand, let updates = body["GlobalSecondaryIndexUpdates"]?.arrayValue {
            let capacity: DynamoDBJSON = .object([
                "ReadCapacityUnits": .number(String(schema.readCapacity ?? 1)),
                "WriteCapacityUnits": .number(String(schema.writeCapacity ?? 1))
            ])
            completed["GlobalSecondaryIndexUpdates"] = .array(updates.map { update in
                guard var create = update["Create"]?.objectValue, create["ProvisionedThroughput"] == nil else { return update }
                create["ProvisionedThroughput"] = capacity
                return .object(["Create": .object(create)])
            })
        }
        return completed
    }

    /// Turning Time to Live off still has to name the attribute it was on, which the Maintenance
    /// menu cannot know when it builds the statement.
    func completingTimeToLive(
        _ body: [String: DynamoDBJSON],
        table: String,
        session: Session
    ) async throws -> [String: DynamoDBJSON] {
        guard var specification = body["TimeToLiveSpecification"]?.objectValue,
              specification["AttributeName"] == nil
        else { return body }
        let response = try await session.client.send(.describeTimeToLive, ["TableName": .string(table)])
        guard let attribute = response["TimeToLiveDescription"]?["AttributeName"]?.stringValue else {
            throw DynamoDBError.invalidStatement(String(localized: "Time to Live is not on for this table"))
        }
        specification["AttributeName"] = .string(attribute)
        var completed = body
        completed["TimeToLiveSpecification"] = .object(specification)
        return completed
    }
}

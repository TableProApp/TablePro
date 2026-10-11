import Foundation
import TableProPluginKit

extension DynamoDBPluginDriver {
    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        DynamoDBWriteStatements(table: table, columns: columns, keyColumns: primaryKeyColumns).statements(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let writer = DynamoDBWriteStatements(table: table, columns: columns, keyColumns: primaryKeyColumns)
        return rows.map { writer.insert(row: $0) }
    }

    // MARK: - PartiQL writes

    func writePartiQL(_ text: String, parameters: [PluginCellValue], session: Session) async throws -> PluginQueryResult {
        let started = Date()
        let kind = DynamoDBPartiQL.kind(of: text)
        let target = DynamoDBPartiQL.target(of: text)
        let schema = await target.asyncMap { try? await tableSchema($0.table, session: session) } ?? nil
        var body: [String: DynamoDBJSON] = [
            "Statement": .string(text),
            "ReturnConsumedCapacity": .string("TOTAL")
        ]
        var boundKey: DynamoDBItem?

        if !parameters.isEmpty {
            let roles = DynamoDBPartiQL.parameterRoles(in: text)
            let table = target?.table
            var observed = table.map { catalog.columnTypes(for: $0, in: session.scope) } ?? [:]
            if kind == .insert, observed.isEmpty, let table {
                observed = try await sampleTypes(table: table, schema: schema, session: session)
            }
            let keyOnly = DynamoDBParameterBinder(schema: schema, observedTypes: observed, currentItem: nil)
            boundKey = try key(from: parameters, roles: roles, schema: schema, binder: keyOnly)
            var current: DynamoDBItem?
            if kind == .update || kind == .delete, let boundKey, let table {
                current = try await currentItem(table: table, key: boundKey, roles: roles, session: session)
                if kind == .update, current == nil {
                    throw DynamoDBError.itemMissing(key: schema?.describeKey(boundKey) ?? "")
                }
            }
            let binder = DynamoDBParameterBinder(schema: schema, observedTypes: observed, currentItem: current)
            let bound = try binder.bind(parameters, roles: roles)
            if kind == .insert, let schema {
                try requireKeys(schema: schema, statement: text, roles: roles, values: bound)
            }
            body["Parameters"] = .array(bound.map(\.wireJSON))
        }

        let response: DynamoDBJSON
        do {
            response = try await session.client.send(.executeStatement, body)
        } catch DynamoDBError.service(let error) where error.isConditionalCheckFailure && kind == .update {
            throw DynamoDBError.itemChanged(key: boundKey.flatMap { schema?.describeKey($0) } ?? "")
        } catch DynamoDBError.service(let error) where error.code.hasPrefix("DuplicateItem") && kind == .insert {
            throw DynamoDBError.invalidValue(attribute: "", reason: String(localized: "An item with this key already exists"))
        }

        if let table = target?.table {
            catalog.forgetReadPositions(table: table, in: session.scope)
        }
        let items = try (response["Items"]?.arrayValue ?? []).map(DynamoDBItem.init(wireItem:))
        let hasReturning = DynamoDBPartiQL.hasReturning(text)
        let rowsAffected: Int
        var message: String?
        switch kind {
        case .insert, .update:
            rowsAffected = 1
        case .delete where hasReturning:
            rowsAffected = items.count
        case .delete:
            rowsAffected = 0
            message = String(localized: "DELETE ran. DynamoDB reports whether an item was deleted only with RETURNING ALL OLD *.")
        default:
            rowsAffected = 0
        }
        if hasReturning, !items.isEmpty {
            return Self.queryResult(
                items: items, schema: schema, preferredColumns: [], includeAllKeys: false,
                started: started, isTruncated: false, statusMessage: message, rowsAffected: rowsAffected
            )
        }
        return Self.messageResult(
            message ?? String(format: String(localized: "%d item(s) affected"), rowsAffected),
            started: started,
            rowsAffected: rowsAffected
        )
    }

    /// The item's key, read out of the `"key" = ?` parameters of a statement that names every key
    /// attribute of the table.
    private func key(
        from parameters: [PluginCellValue],
        roles: [DynamoDBPartiQL.ParameterRole],
        schema: DynamoDBTableSchema?,
        binder: DynamoDBParameterBinder
    ) throws -> DynamoDBItem? {
        guard let schema else { return nil }
        var key: DynamoDBItem = [:]
        for (index, role) in roles.enumerated() where index < parameters.count {
            guard case .compared(let path) = role, path.isTopLevel, schema.keys.attributes.contains(path.root),
                  key[path.root] == nil
            else { continue }
            key[path.root] = try binder.bind([parameters[index]], roles: [role]).first
        }
        return key.count == schema.keys.attributes.count ? key : nil
    }

    /// The attributes an UPDATE or DELETE touches, as the item holds them now: the types its
    /// parameters are decoded against.
    private func currentItem(
        table: String,
        key: DynamoDBItem,
        roles: [DynamoDBPartiQL.ParameterRole],
        session: Session
    ) async throws -> DynamoDBItem? {
        var context = DynamoDBExpressionContext()
        var projected: [String] = []
        for role in roles {
            switch role {
            case .assigned(let path), .compared(let path):
                let placeholder = context.name(path.root)
                if !projected.contains(placeholder) { projected.append(placeholder) }
            default:
                continue
            }
        }
        var body: [String: DynamoDBJSON] = [
            "TableName": .string(table),
            "Key": key.wireJSON,
            "ConsistentRead": .bool(true)
        ]
        if !projected.isEmpty {
            body["ProjectionExpression"] = .string(projected.joined(separator: ", "))
        }
        context.apply(to: &body)
        let response = try await session.client.send(.getItem, body)
        return try response["Item"].map(DynamoDBItem.init(wireItem:))
    }

    /// Every key attribute of the table is in the INSERT, as a literal or as a `?` bound to a value.
    private func requireKeys(
        schema: DynamoDBTableSchema,
        statement: String,
        roles: [DynamoDBPartiQL.ParameterRole],
        values: [DynamoDBAttributeValue]
    ) throws {
        let named = DynamoDBPartiQL.insertedAttributes(in: statement)
        for attribute in schema.keys.attributes {
            let boundToNull = roles.enumerated().contains { index, role in
                guard case .inserted(let name) = role, name == attribute else { return false }
                return index >= values.count || values[index] == .null
            }
            guard named.contains(attribute), !boundToNull else {
                throw DynamoDBError.invalidValue(attribute: attribute, reason: String(localized: "A key attribute needs a value"))
            }
        }
    }

    /// Types for the attributes of a table nothing has read yet, from one small page.
    func sampleTypes(
        table: String,
        schema: DynamoDBTableSchema?,
        session: Session
    ) async throws -> [String: DynamoDBAttributeType] {
        let response = try await session.client.send(.scan, ["TableName": .string(table), "Limit": .number("100")])
        let items = try (response["Items"]?.arrayValue ?? []).map(DynamoDBItem.init(wireItem:))
        let observed = DynamoDBItemTable(items: items, schema: schema).observedTypes
        catalog.mergeColumnTypes(observed, for: table, in: session.scope)
        return observed
    }
}

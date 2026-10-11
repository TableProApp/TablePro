import Foundation
import TableProPluginKit

extension DynamoDBPluginDriver {
    // MARK: - Drop

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        guard objectType.uppercased() == "TABLE", DynamoDBTableDefinition.isValidTableName(name) else { return nil }
        return Self.apiStatement(.deleteTable, ["TableName": .string(name)])
    }

    // MARK: - Create Table form

    func createTableFormSpec(schema: String?) -> PluginCreateTableFormSpec? {
        DynamoDBTableDefinition.formSpec
    }

    func createTableStatements(for request: PluginCreateTableRequest, schema: String?) throws -> [String] {
        let body = try DynamoDBTableDefinition.createTableRequest(from: request)
        return [
            DynamoDBStatement.apiCall(DynamoDBAPICall(operation: .createTable, body: body), window: DynamoDBReadWindow())
                .prettyText
        ]
    }

    // MARK: - Global secondary indexes from the Structure tab

    /// The first column is the partition key and the second, when there is one, the sort key. The
    /// key types and a provisioned table's capacity are filled in when the statement runs.
    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        guard !index.isUnique, (1...2).contains(index.columns.count) else { return nil }
        var keys: [DynamoDBJSON] = [.object(["AttributeName": .string(index.columns[0]), "KeyType": .string("HASH")])]
        if index.columns.count == 2 {
            keys.append(.object(["AttributeName": .string(index.columns[1]), "KeyType": .string("RANGE")]))
        }
        var projection: [String: DynamoDBJSON] = ["ProjectionType": .string("ALL")]
        if let included = index.includedColumns, !included.isEmpty {
            projection = [
                "ProjectionType": .string("INCLUDE"),
                "NonKeyAttributes": .array(included.map(DynamoDBJSON.string))
            ]
        }
        return Self.apiStatement(.updateTable, [
            "TableName": .string(table),
            "GlobalSecondaryIndexUpdates": .array([.object(["Create": .object([
                "IndexName": .string(index.name),
                "KeySchema": .array(keys),
                "Projection": .object(projection)
            ])])])
        ])
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        guard indexName != "PRIMARY" else { return nil }
        return Self.apiStatement(.updateTable, [
            "TableName": .string(table),
            "GlobalSecondaryIndexUpdates": .array([.object(["Delete": .object(["IndexName": .string(indexName)])])])
        ])
    }

    func schemaOperationRefusal(_ operation: PluginSchemaOperation) -> String? {
        switch operation {
        case .addIndex(let index):
            if index.isUnique {
                return String(localized: "DynamoDB indexes are never unique")
            }
            guard (1...2).contains(index.columns.count) else {
                return String(localized: "A global secondary index takes a partition key and an optional sort key")
            }
            return nil
        case .addColumn:
            return String(localized: "A DynamoDB table declares only its keys. Add the attribute by writing it to an item.")
        case .modifyIndex:
            return String(
                localized: "A DynamoDB index can't be changed. Delete it and save, then add the new one once the old one is gone."
            )
        case .dropIndex(let index):
            let type = index.indexType ?? ""
            if index.name == "PRIMARY" || type == DynamoDBIndexTypeName.primary {
                return String(localized: "The primary key is part of the table and can't be dropped.")
            }
            guard type.hasPrefix(DynamoDBIndexTypeName.local) else { return nil }
            return String(localized: "A local secondary index is part of its table and is removed only with the table.")
        default:
            return nil
        }
    }

    // MARK: - Maintenance

    enum MaintenanceName {
        static var pointInTimeRecovery: String { String(localized: "Point-in-Time Recovery") }
        static var deletionProtection: String { String(localized: "Deletion Protection") }
        static var stream: String { String(localized: "Stream") }
        static var tableClass: String { String(localized: "Table Class") }
        static var onDemand: String { String(localized: "Switch to On-Demand Capacity") }
        static var timeToLiveOff: String { String(localized: "Turn Off Time to Live") }
    }

    private enum MaintenanceOption {
        static let enabled = "enabled"
        static let choice = "choice"
    }

    private static var streamChoices: [(label: String, viewType: String?)] {
        [
            (String(localized: "Off"), nil),
            (String(localized: "Keys only"), "KEYS_ONLY"),
            (String(localized: "New image"), "NEW_IMAGE"),
            (String(localized: "Old image"), "OLD_IMAGE"),
            (String(localized: "New and old images"), "NEW_AND_OLD_IMAGES")
        ]
    }

    private static var tableClassChoices: [(label: String, value: String)] {
        [
            (String(localized: "Standard"), "STANDARD"),
            (String(localized: "Standard-Infrequent Access"), "STANDARD_INFREQUENT_ACCESS")
        ]
    }

    func maintenanceOperations() -> [PluginMaintenanceOperation]? {
        let tables: Set<PluginObjectKind> = [.table]
        return [
            PluginMaintenanceOperation(
                name: MaintenanceName.pointInTimeRecovery, appliesTo: tables, scope: .object,
                options: [PluginMaintenanceOption(key: MaintenanceOption.enabled, label: String(localized: "On"), defaultValue: "true")]
            ),
            PluginMaintenanceOperation(
                name: MaintenanceName.deletionProtection, appliesTo: tables, scope: .object,
                options: [PluginMaintenanceOption(key: MaintenanceOption.enabled, label: String(localized: "On"), defaultValue: "true")]
            ),
            PluginMaintenanceOperation(
                name: MaintenanceName.stream, appliesTo: tables, scope: .object,
                options: [PluginMaintenanceOption(
                    key: MaintenanceOption.choice, label: String(localized: "Stream"),
                    defaultValue: Self.streamChoices[4].label, choices: Self.streamChoices.map(\.label)
                )]
            ),
            PluginMaintenanceOperation(
                name: MaintenanceName.tableClass, appliesTo: tables, scope: .object,
                options: [PluginMaintenanceOption(
                    key: MaintenanceOption.choice, label: String(localized: "Class"),
                    defaultValue: Self.tableClassChoices[0].label, choices: Self.tableClassChoices.map(\.label)
                )]
            ),
            PluginMaintenanceOperation(name: MaintenanceName.onDemand, appliesTo: tables, scope: .object),
            PluginMaintenanceOperation(name: MaintenanceName.timeToLiveOff, appliesTo: tables, scope: .object)
        ]
    }

    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]? {
        guard let table else { return nil }
        let name: DynamoDBJSON = .string(table)
        let enabled = options[MaintenanceOption.enabled] != "false"
        switch operation {
        case MaintenanceName.pointInTimeRecovery:
            return [Self.apiStatement(.updateContinuousBackups, [
                "TableName": name,
                "PointInTimeRecoverySpecification": .object(["PointInTimeRecoveryEnabled": .bool(enabled)])
            ])]
        case MaintenanceName.deletionProtection:
            return [Self.apiStatement(.updateTable, ["TableName": name, "DeletionProtectionEnabled": .bool(enabled)])]
        case MaintenanceName.stream:
            let choice = Self.streamChoices.first { $0.label == options[MaintenanceOption.choice] }
            guard let choice else { return nil }
            var specification: [String: DynamoDBJSON] = ["StreamEnabled": .bool(choice.viewType != nil)]
            if let viewType = choice.viewType { specification["StreamViewType"] = .string(viewType) }
            return [Self.apiStatement(.updateTable, ["TableName": name, "StreamSpecification": .object(specification)])]
        case MaintenanceName.tableClass:
            guard let choice = Self.tableClassChoices.first(where: { $0.label == options[MaintenanceOption.choice] }) else {
                return nil
            }
            return [Self.apiStatement(.updateTable, ["TableName": name, "TableClass": .string(choice.value)])]
        case MaintenanceName.onDemand:
            return [Self.apiStatement(.updateTable, ["TableName": name, "BillingMode": .string("PAY_PER_REQUEST")])]
        case MaintenanceName.timeToLiveOff:
            return [Self.apiStatement(.updateTimeToLive, [
                "TableName": name,
                "TimeToLiveSpecification": .object(["Enabled": .bool(false)])
            ])]
        default:
            return nil
        }
    }

    static func apiStatement(_ operation: DynamoDBOperation, _ body: [String: DynamoDBJSON]) -> String {
        DynamoDBStatement.apiCall(DynamoDBAPICall(operation: operation, body: .object(body)), window: DynamoDBReadWindow()).text
    }
}

import Foundation
import TableProPluginKit

/// Table definitions as `CreateTable` requests: rebuilt from a described table for the DDL view,
/// and built from the Create Table form.
enum DynamoDBTableDefinition {
    static func isValidTableName(_ name: String) -> Bool {
        guard (3...255).contains(name.count) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "."
        }
    }

    // MARK: - From a described table

    static func createTableRequest(_ schema: DynamoDBTableSchema) -> DynamoDBJSON {
        var body: [String: DynamoDBJSON] = [
            "TableName": .string(schema.name),
            "KeySchema": keySchema(schema.keys),
            "AttributeDefinitions": .array(schema.attributeTypes.keys.sorted().compactMap { name in
                schema.attributeTypes[name].map { attributeDefinition(name, $0) }
            }),
            "BillingMode": .string(schema.isOnDemand ? "PAY_PER_REQUEST" : "PROVISIONED")
        ]
        if !schema.isOnDemand {
            body["ProvisionedThroughput"] = throughput(read: schema.readCapacity, write: schema.writeCapacity)
        }
        let globals = schema.indexes.filter { $0.kind == .global }
        if !globals.isEmpty {
            body["GlobalSecondaryIndexes"] = .array(globals.map { index in
                var entry = indexBody(index)
                if !schema.isOnDemand {
                    entry["ProvisionedThroughput"] = throughput(read: index.readCapacity, write: index.writeCapacity)
                }
                return .object(entry)
            })
        }
        let locals = schema.indexes.filter { $0.kind == .local }
        if !locals.isEmpty {
            body["LocalSecondaryIndexes"] = .array(locals.map { .object(indexBody($0)) })
        }
        if let tableClass = schema.tableClass {
            body["TableClass"] = .string(tableClass)
        }
        if schema.deletionProtection {
            body["DeletionProtectionEnabled"] = .bool(true)
        }
        if let viewType = schema.streamViewType {
            body["StreamSpecification"] = .object(["StreamEnabled": .bool(true), "StreamViewType": .string(viewType)])
        }
        if schema.sseType == "KMS" {
            var sse: [String: DynamoDBJSON] = ["Enabled": .bool(true), "SSEType": .string("KMS")]
            if let key = schema.sseKeyArn { sse["KMSMasterKeyId"] = .string(key) }
            body["SSESpecification"] = .object(sse)
        }
        return .object(body)
    }

    static func summary(_ schema: DynamoDBTableSchema) -> String {
        var parts: [String] = []
        if schema.isOnDemand {
            parts.append(String(localized: "On-demand capacity"))
        } else {
            parts.append(String(
                format: String(localized: "Provisioned: %1$lld read, %2$lld write"),
                schema.readCapacity ?? 0, schema.writeCapacity ?? 0
            ))
        }
        if let tableClass = schema.tableClass {
            parts.append(tableClass == "STANDARD_INFREQUENT_ACCESS"
                ? String(localized: "Standard-Infrequent Access") : String(localized: "Standard"))
        }
        if schema.deletionProtection {
            parts.append(String(localized: "Deletion protection on"))
        }
        if let viewType = schema.streamViewType {
            parts.append(String(format: String(localized: "Stream: %@"), viewType))
        }
        if let status = schema.status, status != "ACTIVE" {
            parts.append(String(format: String(localized: "Status: %@"), status))
        }
        parts.append(String(localized: "Item count is approximate, updated about every six hours"))
        return parts.joined(separator: " · ")
    }

    private static func keySchema(_ keys: DynamoDBKeySchema) -> DynamoDBJSON {
        .array(
            keys.partition.map { .object(["AttributeName": .string($0), "KeyType": .string("HASH")]) }
                + keys.sort.map { .object(["AttributeName": .string($0), "KeyType": .string("RANGE")]) }
        )
    }

    private static func attributeDefinition(_ name: String, _ type: DynamoDBAttributeType) -> DynamoDBJSON {
        .object(["AttributeName": .string(name), "AttributeType": .string(type.rawValue)])
    }

    private static func throughput(read: Int64?, write: Int64?) -> DynamoDBJSON {
        .object([
            "ReadCapacityUnits": .number(String(read ?? 1)),
            "WriteCapacityUnits": .number(String(write ?? 1))
        ])
    }

    private static func indexBody(_ index: DynamoDBIndex) -> [String: DynamoDBJSON] {
        [
            "IndexName": .string(index.name),
            "KeySchema": keySchema(index.keys),
            "Projection": projection(index.projection)
        ]
    }

    private static func projection(_ projection: DynamoDBProjection) -> DynamoDBJSON {
        switch projection {
        case .all:
            return .object(["ProjectionType": .string("ALL")])
        case .keysOnly:
            return .object(["ProjectionType": .string("KEYS_ONLY")])
        case .include(let attributes):
            return .object([
                "ProjectionType": .string("INCLUDE"),
                "NonKeyAttributes": .array(attributes.map(DynamoDBJSON.string))
            ])
        }
    }

    // MARK: - Create Table form

    enum Field {
        static let partitionKeyName = "partitionKeyName"
        static let partitionKeyType = "partitionKeyType"
        static let sortKeyName = "sortKeyName"
        static let sortKeyType = "sortKeyType"
        static let billingMode = "billingMode"
        static let readCapacity = "readCapacity"
        static let writeCapacity = "writeCapacity"
        static let tableClass = "tableClass"
        static let deletionProtection = "deletionProtection"
        static let indexName = "indexName"
        static let projection = "projection"
        static let includedAttributes = "includedAttributes"
        static let globalIndexes = "globalIndexes"
        static let localIndexes = "localIndexes"
    }

    static var formSpec: PluginCreateTableFormSpec {
        PluginCreateTableFormSpec(
            sections: [
                PluginFormSection(id: "keys", title: String(localized: "Primary Key"), fields: [
                    PluginFormField(
                        id: Field.partitionKeyName, label: String(localized: "Partition key"),
                        kind: .text(placeholder: "pk", isRequired: true)
                    ),
                    PluginFormField(id: Field.partitionKeyType, label: String(localized: "Type"), kind: keyTypePicker),
                    PluginFormField(
                        id: Field.sortKeyName, label: String(localized: "Sort key"),
                        kind: .text(placeholder: String(localized: "Optional"), isRequired: false)
                    ),
                    PluginFormField(
                        id: Field.sortKeyType, label: String(localized: "Type"), kind: keyTypePicker,
                        visibleWhen: PluginFormCondition(fieldId: Field.sortKeyName, values: nil)
                    )
                ]),
                PluginFormSection(id: "capacity", title: String(localized: "Capacity"), fields: [
                    PluginFormField(
                        id: Field.billingMode, label: String(localized: "Billing"),
                        kind: .picker(options: [
                            PluginFormOption(value: "PAY_PER_REQUEST", label: String(localized: "On-demand")),
                            PluginFormOption(value: "PROVISIONED", label: String(localized: "Provisioned"))
                        ], defaultValue: "PAY_PER_REQUEST")
                    ),
                    PluginFormField(
                        id: Field.readCapacity, label: String(localized: "Read capacity units"),
                        kind: .integer(defaultValue: 5, minimum: 1, maximum: nil),
                        visibleWhen: PluginFormCondition(fieldId: Field.billingMode, values: ["PROVISIONED"])
                    ),
                    PluginFormField(
                        id: Field.writeCapacity, label: String(localized: "Write capacity units"),
                        kind: .integer(defaultValue: 5, minimum: 1, maximum: nil),
                        visibleWhen: PluginFormCondition(fieldId: Field.billingMode, values: ["PROVISIONED"])
                    )
                ]),
                PluginFormSection(id: "settings", title: String(localized: "Settings"), fields: [
                    PluginFormField(
                        id: Field.tableClass, label: String(localized: "Table class"),
                        kind: .picker(options: [
                            PluginFormOption(value: "STANDARD", label: String(localized: "Standard")),
                            PluginFormOption(
                                value: "STANDARD_INFREQUENT_ACCESS", label: String(localized: "Standard-Infrequent Access")
                            )
                        ], defaultValue: "STANDARD")
                    ),
                    PluginFormField(
                        id: Field.deletionProtection, label: String(localized: "Deletion protection"),
                        kind: .toggle(defaultValue: false)
                    )
                ]),
                PluginFormSection(
                    id: Field.globalIndexes, title: String(localized: "Global Secondary Indexes"),
                    fields: indexFields(includesPartitionKey: true),
                    isRepeating: true, addLabel: String(localized: "Add Global Index"), maximumCount: 20
                ),
                PluginFormSection(
                    id: Field.localIndexes, title: String(localized: "Local Secondary Indexes"),
                    fields: indexFields(includesPartitionKey: false),
                    isRepeating: true, addLabel: String(localized: "Add Local Index"), maximumCount: 5
                )
            ],
            footnote: String(localized: "A DynamoDB table declares only its key attributes. The items you write add every other attribute.")
        )
    }

    private static var keyTypePicker: PluginFormField.Kind {
        .picker(options: [
            PluginFormOption(value: "S", label: DynamoDBAttributeType.string.displayName),
            PluginFormOption(value: "N", label: DynamoDBAttributeType.number.displayName),
            PluginFormOption(value: "B", label: DynamoDBAttributeType.binary.displayName)
        ], defaultValue: "S")
    }

    private static func indexFields(includesPartitionKey: Bool) -> [PluginFormField] {
        var fields = [
            PluginFormField(
                id: Field.indexName, label: String(localized: "Index name"),
                kind: .text(placeholder: nil, isRequired: true)
            )
        ]
        if includesPartitionKey {
            fields += [
                PluginFormField(
                    id: Field.partitionKeyName, label: String(localized: "Partition key"),
                    kind: .text(placeholder: nil, isRequired: true)
                ),
                PluginFormField(id: Field.partitionKeyType, label: String(localized: "Type"), kind: keyTypePicker)
            ]
        }
        fields += [
            PluginFormField(
                id: Field.sortKeyName, label: String(localized: "Sort key"),
                kind: .text(placeholder: includesPartitionKey ? String(localized: "Optional") : nil, isRequired: !includesPartitionKey)
            ),
            PluginFormField(
                id: Field.sortKeyType, label: String(localized: "Type"), kind: keyTypePicker,
                visibleWhen: PluginFormCondition(fieldId: Field.sortKeyName, values: nil)
            ),
            PluginFormField(
                id: Field.projection, label: String(localized: "Attributes"),
                kind: .picker(options: [
                    PluginFormOption(value: "ALL", label: String(localized: "All attributes")),
                    PluginFormOption(value: "KEYS_ONLY", label: String(localized: "Keys only")),
                    PluginFormOption(value: "INCLUDE", label: String(localized: "Keys and chosen attributes"))
                ], defaultValue: "ALL")
            ),
            PluginFormField(
                id: Field.includedAttributes, label: String(localized: "Chosen attributes"),
                kind: .text(placeholder: String(localized: "Comma-separated names"), isRequired: true),
                visibleWhen: PluginFormCondition(fieldId: Field.projection, values: ["INCLUDE"])
            )
        ]
        return fields
    }

    static func createTableRequest(from request: PluginCreateTableRequest) throws -> DynamoDBJSON {
        let tableName = request.tableName.trimmingCharacters(in: .whitespaces)
        guard isValidTableName(tableName) else {
            throw PluginCreateTableFormError(message: String(
                localized: "A table name is 3 to 255 characters of letters, digits, underscore, hyphen and period."
            ))
        }
        var types: [String: DynamoDBAttributeType] = [:]
        func declare(_ name: String, _ typeValue: String?, field: String) throws {
            let type = typeValue.flatMap(DynamoDBAttributeType.init(rawValue:)) ?? .string
            if let existing = types[name], existing != type {
                throw PluginCreateTableFormError(
                    message: String(format: String(localized: "\"%@\" is declared as two different types"), name),
                    fieldId: field
                )
            }
            types[name] = type
        }

        let values = request.values
        let partition = trimmed(values[Field.partitionKeyName])
        guard !partition.isEmpty else {
            throw PluginCreateTableFormError(
                message: String(localized: "Enter the partition key's name"), fieldId: Field.partitionKeyName
            )
        }
        try declare(partition, values[Field.partitionKeyType], field: Field.partitionKeyType)
        let sort = trimmed(values[Field.sortKeyName])
        if !sort.isEmpty {
            try declare(sort, values[Field.sortKeyType], field: Field.sortKeyType)
        }
        let tableKeys = DynamoDBKeySchema(partition: [partition], sort: sort.isEmpty ? [] : [sort])

        let isProvisioned = values[Field.billingMode] == "PROVISIONED"
        let capacity = try isProvisioned ? provisionedThroughput(values) : nil

        let globals = try (request.repeatedValues[Field.globalIndexes] ?? []).map { entry in
            try indexRequest(entry, tablePartition: nil, declare: declare, capacity: capacity)
        }
        let localEntries = request.repeatedValues[Field.localIndexes] ?? []
        if !localEntries.isEmpty, sort.isEmpty {
            throw PluginCreateTableFormError(
                message: String(localized: "A local secondary index needs a table with a sort key"),
                fieldId: Field.sortKeyName
            )
        }
        let locals = try localEntries.map { entry in
            try indexRequest(entry, tablePartition: partition, declare: declare, capacity: nil)
        }

        var body: [String: DynamoDBJSON] = [
            "TableName": .string(tableName),
            "KeySchema": keySchema(tableKeys),
            "AttributeDefinitions": .array(types.keys.sorted().compactMap { name in
                types[name].map { attributeDefinition(name, $0) }
            }),
            "BillingMode": .string(isProvisioned ? "PROVISIONED" : "PAY_PER_REQUEST")
        ]
        if let capacity { body["ProvisionedThroughput"] = capacity }
        if !globals.isEmpty { body["GlobalSecondaryIndexes"] = .array(globals) }
        if !locals.isEmpty { body["LocalSecondaryIndexes"] = .array(locals) }
        if let tableClass = values[Field.tableClass], tableClass != "STANDARD" {
            body["TableClass"] = .string(tableClass)
        }
        if values[Field.deletionProtection] == "true" {
            body["DeletionProtectionEnabled"] = .bool(true)
        }
        return .object(body)
    }

    private static func indexRequest(
        _ entry: [String: String],
        tablePartition: String?,
        declare: (String, String?, String) throws -> Void,
        capacity: DynamoDBJSON?
    ) throws -> DynamoDBJSON {
        let name = trimmed(entry[Field.indexName])
        guard isValidTableName(name) else {
            throw PluginCreateTableFormError(
                message: String(localized: "An index name is 3 to 255 characters of letters, digits, underscore, hyphen and period."),
                fieldId: Field.indexName
            )
        }
        let partition = tablePartition ?? trimmed(entry[Field.partitionKeyName])
        guard !partition.isEmpty else {
            throw PluginCreateTableFormError(
                message: String(format: String(localized: "Enter the partition key of index %@"), name),
                fieldId: Field.partitionKeyName
            )
        }
        if tablePartition == nil {
            try declare(partition, entry[Field.partitionKeyType], Field.partitionKeyType)
        }
        let sort = trimmed(entry[Field.sortKeyName])
        if tablePartition != nil, sort.isEmpty {
            throw PluginCreateTableFormError(
                message: String(format: String(localized: "Enter the sort key of index %@"), name),
                fieldId: Field.sortKeyName
            )
        }
        if !sort.isEmpty {
            try declare(sort, entry[Field.sortKeyType], Field.sortKeyType)
        }
        let projectionType = entry[Field.projection] ?? "ALL"
        var projection: [String: DynamoDBJSON] = ["ProjectionType": .string(projectionType)]
        if projectionType == "INCLUDE" {
            let attributes = (entry[Field.includedAttributes] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !attributes.isEmpty else {
                throw PluginCreateTableFormError(
                    message: String(format: String(localized: "Name the attributes index %@ includes"), name),
                    fieldId: Field.includedAttributes
                )
            }
            projection["NonKeyAttributes"] = .array(attributes.map(DynamoDBJSON.string))
        }
        var body: [String: DynamoDBJSON] = [
            "IndexName": .string(name),
            "KeySchema": keySchema(DynamoDBKeySchema(partition: [partition], sort: sort.isEmpty ? [] : [sort])),
            "Projection": .object(projection)
        ]
        if let capacity { body["ProvisionedThroughput"] = capacity }
        return .object(body)
    }

    private static func provisionedThroughput(_ values: [String: String]) throws -> DynamoDBJSON {
        guard let read = Int(trimmed(values[Field.readCapacity])), read >= 1 else {
            throw PluginCreateTableFormError(
                message: String(localized: "Read capacity must be a whole number of at least 1"), fieldId: Field.readCapacity
            )
        }
        guard let write = Int(trimmed(values[Field.writeCapacity])), write >= 1 else {
            throw PluginCreateTableFormError(
                message: String(localized: "Write capacity must be a whole number of at least 1"), fieldId: Field.writeCapacity
            )
        }
        return .object(["ReadCapacityUnits": .number(String(read)), "WriteCapacityUnits": .number(String(write))])
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

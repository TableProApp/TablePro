import Foundation
import TableProPluginKit

/// The key attributes of a table or an index, in declaration order.
///
/// A global secondary index may name up to four partition and four sort attributes, so neither
/// half is a single name.
struct DynamoDBKeySchema: Sendable, Equatable {
    let partition: [String]
    let sort: [String]

    var attributes: [String] { partition + sort }

    init(partition: [String], sort: [String]) {
        self.partition = partition
        self.sort = sort
    }

    init(json: DynamoDBJSON?) {
        var partition: [String] = []
        var sort: [String] = []
        for element in json?.arrayValue ?? [] {
            guard let name = element["AttributeName"]?.stringValue else { continue }
            if element["KeyType"]?.stringValue == "RANGE" {
                sort.append(name)
            } else {
                partition.append(name)
            }
        }
        self.init(partition: partition, sort: sort)
    }
}

enum DynamoDBProjection: Sendable, Equatable {
    case all
    case keysOnly
    case include([String])

    init(json: DynamoDBJSON?) {
        switch json?["ProjectionType"]?.stringValue {
        case "KEYS_ONLY":
            self = .keysOnly
        case "INCLUDE":
            self = .include((json?["NonKeyAttributes"]?.arrayValue ?? []).compactMap(\.stringValue))
        default:
            self = .all
        }
    }

    var displayName: String {
        switch self {
        case .all: return "ALL"
        case .keysOnly: return "KEYS_ONLY"
        case .include: return "INCLUDE"
        }
    }

    var nonKeyAttributes: [String] {
        guard case .include(let attributes) = self else { return [] }
        return attributes
    }
}

struct DynamoDBIndex: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case global
        case local
    }

    let name: String
    let kind: Kind
    let keys: DynamoDBKeySchema
    let projection: DynamoDBProjection
    let status: String?
    let isBackfilling: Bool
    let itemCount: Int64?
    let sizeBytes: Int64?
    let readCapacity: Int64?
    let writeCapacity: Int64?

    /// A query can be answered from the index now. A global index being built or deleted is not,
    /// and one still backfilling misses items.
    var isQueryable: Bool {
        guard kind == .global else { return true }
        return (status == nil || status == "ACTIVE") && !isBackfilling
    }
}

struct DynamoDBTableSchema: Sendable, Equatable {
    let name: String
    let keys: DynamoDBKeySchema
    let attributeTypes: [String: DynamoDBAttributeType]
    let indexes: [DynamoDBIndex]
    let status: String?
    let arn: String?
    let itemCount: Int64?
    let sizeBytes: Int64?
    let billingMode: String
    let readCapacity: Int64?
    let writeCapacity: Int64?
    let tableClass: String?
    let deletionProtection: Bool
    let streamViewType: String?
    let sseType: String?
    let sseKeyArn: String?
    let createdAt: Date?

    var isOnDemand: Bool { billingMode == "PAY_PER_REQUEST" }

    /// A table DynamoDB is still creating answers DescribeTable and nothing else yet.
    var isBeingCreated: Bool { status == "CREATING" }

    var allKeyAttributes: Set<String> {
        Set(keys.attributes + indexes.flatMap(\.keys.attributes))
    }

    func index(named name: String) -> DynamoDBIndex? {
        indexes.first { $0.name == name }
    }

    func keyType(of attribute: String) -> DynamoDBAttributeType? {
        attributeTypes[attribute]
    }

    init(describeTableResponse json: DynamoDBJSON) throws {
        guard let table = json["Table"], let name = table["TableName"]?.stringValue else {
            throw DynamoDBError.invalidResponse(String(localized: "DescribeTable returned no table"))
        }
        self.name = name
        self.keys = DynamoDBKeySchema(json: table["KeySchema"])
        var types: [String: DynamoDBAttributeType] = [:]
        for definition in table["AttributeDefinitions"]?.arrayValue ?? [] {
            guard let attribute = definition["AttributeName"]?.stringValue,
                  let type = definition["AttributeType"]?.stringValue.flatMap(DynamoDBAttributeType.init(rawValue:))
            else { continue }
            types[attribute] = type
        }
        self.attributeTypes = types
        let globals = (table["GlobalSecondaryIndexes"]?.arrayValue ?? []).map { Self.index($0, kind: .global) }
        let locals = (table["LocalSecondaryIndexes"]?.arrayValue ?? []).map { Self.index($0, kind: .local) }
        self.indexes = globals + locals
        self.status = table["TableStatus"]?.stringValue
        self.arn = table["TableArn"]?.stringValue
        self.itemCount = table["ItemCount"]?.numberText.flatMap { Int64($0) }
        self.sizeBytes = table["TableSizeBytes"]?.numberText.flatMap { Int64($0) }
        self.billingMode = table["BillingModeSummary"]?["BillingMode"]?.stringValue ?? "PROVISIONED"
        self.readCapacity = table["ProvisionedThroughput"]?["ReadCapacityUnits"]?.numberText.flatMap { Int64($0) }
        self.writeCapacity = table["ProvisionedThroughput"]?["WriteCapacityUnits"]?.numberText.flatMap { Int64($0) }
        self.tableClass = table["TableClassSummary"]?["TableClass"]?.stringValue
        self.deletionProtection = table["DeletionProtectionEnabled"]?.boolValue ?? false
        let streamEnabled = table["StreamSpecification"]?["StreamEnabled"]?.boolValue ?? false
        self.streamViewType = streamEnabled ? table["StreamSpecification"]?["StreamViewType"]?.stringValue : nil
        self.sseType = table["SSEDescription"]?["SSEType"]?.stringValue
        self.sseKeyArn = table["SSEDescription"]?["KMSMasterKeyArn"]?.stringValue
        self.createdAt = table["CreationDateTime"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
    }

    private static func index(_ json: DynamoDBJSON, kind: DynamoDBIndex.Kind) -> DynamoDBIndex {
        DynamoDBIndex(
            name: json["IndexName"]?.stringValue ?? "",
            kind: kind,
            keys: DynamoDBKeySchema(json: json["KeySchema"]),
            projection: DynamoDBProjection(json: json["Projection"]),
            status: json["IndexStatus"]?.stringValue,
            isBackfilling: json["Backfilling"]?.boolValue ?? false,
            itemCount: json["ItemCount"]?.numberText.flatMap { Int64($0) },
            sizeBytes: json["IndexSizeBytes"]?.numberText.flatMap { Int64($0) },
            readCapacity: json["ProvisionedThroughput"]?["ReadCapacityUnits"]?.numberText.flatMap { Int64($0) },
            writeCapacity: json["ProvisionedThroughput"]?["WriteCapacityUnits"]?.numberText.flatMap { Int64($0) }
        )
    }

    /// The key of `item` as an `ExclusiveStartKey` for a read on `index`, or on the table when nil:
    /// the table's key attributes plus the index's own.
    func startKey(for item: DynamoDBItem, index: DynamoDBIndex?) -> DynamoDBItem? {
        var names = keys.attributes
        if let index {
            names += index.keys.attributes.filter { !names.contains($0) }
        }
        var key: DynamoDBItem = [:]
        for name in names {
            guard let value = item[name] else { return nil }
            key[name] = value
        }
        return key
    }

    func primaryKey(of item: DynamoDBItem) -> DynamoDBItem? {
        startKey(for: item, index: nil)
    }

    /// How the Structure tab and error messages name an item: `pk = a, sk = 3`.
    func describeKey(_ key: DynamoDBItem) -> String {
        keys.attributes.compactMap { name in
            key[name].map { "\(name) = \(DynamoDBCellCodec.displayText(for: $0))" }
        }.joined(separator: ", ")
    }
}

extension DynamoDBCellCodec {
    static func displayText(for value: DynamoDBAttributeValue) -> String {
        switch cell(for: value) {
        case .text(let text): return text
        case .bytes(let data): return data.base64EncodedString()
        case .null: return "NULL"
        }
    }
}

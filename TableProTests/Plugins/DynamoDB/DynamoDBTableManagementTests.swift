//
//  DynamoDBTableManagementTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct DynamoDBTableManagementTests {
    private typealias Field = DynamoDBTableDefinition.Field

    private static let driver = DynamoDBPluginDriver(
        config: DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: ""),
        catalog: DynamoDBCatalog()
    )

    private static func request(_ text: String) throws -> DynamoDBJSON {
        let statement = try DynamoDBStatement.parse(text)
        guard case .apiCall(let call, _) = statement else {
            Issue.record("Not an API call: \(text)")
            return .null
        }
        return call.body
    }

    private static func formError(_ body: () throws -> Void) -> PluginCreateTableFormError? {
        do {
            try body()
            return nil
        } catch let error as PluginCreateTableFormError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - Create Table form

    @Test("A table with only a partition key is on-demand and declares that key alone")
    func minimalTable() throws {
        let body = try DynamoDBTableDefinition.createTableRequest(from: PluginCreateTableRequest(
            tableName: " Orders ", values: [Field.partitionKeyName: "pk", Field.partitionKeyType: "S"]
        ))

        #expect(body["TableName"] == .string("Orders"))
        #expect(body["BillingMode"] == .string("PAY_PER_REQUEST"))
        #expect(body["KeySchema"] == .array([.object(["AttributeName": .string("pk"), "KeyType": .string("HASH")])]))
        #expect(body["AttributeDefinitions"] == .array([
            .object(["AttributeName": .string("pk"), "AttributeType": .string("S")])
        ]))
        #expect(body["ProvisionedThroughput"] == nil)
        #expect(body["TableClass"] == nil)
        #expect(body["DeletionProtectionEnabled"] == nil)
    }

    @Test("A provisioned table gives its global indexes the same capacity and declares each key once")
    func provisionedTableWithIndexes() throws {
        let body = try DynamoDBTableDefinition.createTableRequest(from: PluginCreateTableRequest(
            tableName: "Orders",
            values: [
                Field.partitionKeyName: "pk", Field.partitionKeyType: "S",
                Field.sortKeyName: "sk", Field.sortKeyType: "N",
                Field.billingMode: "PROVISIONED", Field.readCapacity: "5", Field.writeCapacity: "7",
                Field.tableClass: "STANDARD_INFREQUENT_ACCESS", Field.deletionProtection: "true"
            ],
            repeatedValues: [
                Field.globalIndexes: [[
                    Field.indexName: "byStatus", Field.partitionKeyName: "status", Field.partitionKeyType: "S",
                    Field.sortKeyName: "sk", Field.sortKeyType: "N", Field.projection: "KEYS_ONLY"
                ]],
                Field.localIndexes: [[
                    Field.indexName: "byTotal", Field.sortKeyName: "total", Field.sortKeyType: "N",
                    Field.projection: "INCLUDE", Field.includedAttributes: "a, b"
                ]]
            ]
        ))

        let capacity: DynamoDBJSON = .object(["ReadCapacityUnits": .number("5"), "WriteCapacityUnits": .number("7")])
        let global = body["GlobalSecondaryIndexes"]?.arrayValue?.first
        let local = body["LocalSecondaryIndexes"]?.arrayValue?.first
        let declared = body["AttributeDefinitions"]?.arrayValue?.compactMap { $0["AttributeName"]?.stringValue }
        #expect(body["ProvisionedThroughput"] == capacity)
        #expect(global?["ProvisionedThroughput"] == capacity)
        #expect(global?["Projection"] == .object(["ProjectionType": .string("KEYS_ONLY")]))
        #expect(local?["ProvisionedThroughput"] == nil)
        #expect(local?["KeySchema"]?.arrayValue?.first?["AttributeName"] == .string("pk"))
        #expect(local?["Projection"]?["NonKeyAttributes"] == .array([.string("a"), .string("b")]))
        #expect(declared == ["pk", "sk", "status", "total"])
        #expect(body["TableClass"] == .string("STANDARD_INFREQUENT_ACCESS"))
        #expect(body["DeletionProtectionEnabled"] == .bool(true))
    }

    @Test("A local index on a table without a sort key is refused at the sort key field")
    func localIndexNeedsTableSortKey() {
        let error = Self.formError {
            _ = try DynamoDBTableDefinition.createTableRequest(from: PluginCreateTableRequest(
                tableName: "Orders",
                values: [Field.partitionKeyName: "pk"],
                repeatedValues: [Field.localIndexes: [[Field.indexName: "byTotal", Field.sortKeyName: "total"]]]
            ))
        }

        #expect(error?.fieldId == Field.sortKeyName)
    }

    @Test("An attribute declared as two types is refused")
    func conflictingTypesAreRefused() {
        let error = Self.formError {
            _ = try DynamoDBTableDefinition.createTableRequest(from: PluginCreateTableRequest(
                tableName: "Orders",
                values: [Field.partitionKeyName: "pk", Field.partitionKeyType: "S"],
                repeatedValues: [Field.globalIndexes: [[
                    Field.indexName: "byPk", Field.partitionKeyName: "pk", Field.partitionKeyType: "N"
                ]]]
            ))
        }

        #expect(error?.fieldId == Field.partitionKeyType)
    }

    @Test("An incomplete form names the field to fix")
    func incompleteFormNamesField() {
        let cases: [(values: [String: String], field: String)] = [
            ([Field.partitionKeyName: "pk", Field.billingMode: "PROVISIONED", Field.writeCapacity: "1"], Field.readCapacity),
            (
                [Field.partitionKeyName: "pk", Field.billingMode: "PROVISIONED", Field.readCapacity: "1", Field.writeCapacity: "0"],
                Field.writeCapacity
            ),
            ([Field.partitionKeyName: " "], Field.partitionKeyName)
        ]
        for testCase in cases {
            let error = Self.formError {
                _ = try DynamoDBTableDefinition.createTableRequest(
                    from: PluginCreateTableRequest(tableName: "Orders", values: testCase.values)
                )
            }
            #expect(error?.fieldId == testCase.field, "\(testCase.values)")
        }
    }

    @Test("An included projection with no attributes is refused")
    func includeNeedsAttributes() {
        let error = Self.formError {
            _ = try DynamoDBTableDefinition.createTableRequest(from: PluginCreateTableRequest(
                tableName: "Orders",
                values: [Field.partitionKeyName: "pk"],
                repeatedValues: [Field.globalIndexes: [[
                    Field.indexName: "byStatus", Field.partitionKeyName: "status", Field.projection: "INCLUDE"
                ]]]
            ))
        }

        #expect(error?.fieldId == Field.includedAttributes)
    }

    @Test("A table name DynamoDB would reject is refused", arguments: ["ab", "has space", String(repeating: "a", count: 256)])
    func invalidTableNameIsRefused(name: String) {
        let error = Self.formError {
            _ = try DynamoDBTableDefinition.createTableRequest(from: PluginCreateTableRequest(
                tableName: name, values: [Field.partitionKeyName: "pk"]
            ))
        }

        #expect(error != nil)
    }

    @Test("The form's statement is a CreateTable request the editor parses back")
    func formStatementRoundTrips() throws {
        let statements = try Self.driver.createTableStatements(
            for: PluginCreateTableRequest(tableName: "Orders", values: [Field.partitionKeyName: "pk"]), schema: nil
        )

        let body = try Self.request(try #require(statements.first))
        #expect(statements.count == 1)
        #expect(body["TableName"] == .string("Orders"))
    }

    // MARK: - Maintenance

    @Test("A stream turned off sends no view type")
    func streamOff() throws {
        let statement = try #require(Self.driver.maintenanceStatements(
            operation: DynamoDBPluginDriver.MaintenanceName.stream, table: "Orders", schema: nil,
            options: ["choice": String(localized: "Off")]
        )?.first)

        let body = try Self.request(statement)
        #expect(body["StreamSpecification"] == .object(["StreamEnabled": .bool(false)]))
    }

    @Test("A stream turned on sends the chosen view type")
    func streamOn() throws {
        let statement = try #require(Self.driver.maintenanceStatements(
            operation: DynamoDBPluginDriver.MaintenanceName.stream, table: "Orders", schema: nil,
            options: ["choice": String(localized: "Keys only")]
        )?.first)

        let body = try Self.request(statement)
        #expect(body["StreamSpecification"] == .object([
            "StreamEnabled": .bool(true), "StreamViewType": .string("KEYS_ONLY")
        ]))
    }

    @Test("Each setting becomes the request that changes it")
    func maintenanceRequests() throws {
        let name = DynamoDBPluginDriver.MaintenanceName.self
        let recovery = try Self.request(try #require(Self.driver.maintenanceStatements(
            operation: name.pointInTimeRecovery, table: "Orders", schema: nil, options: ["enabled": "false"]
        )?.first))
        let protection = try Self.request(try #require(Self.driver.maintenanceStatements(
            operation: name.deletionProtection, table: "Orders", schema: nil, options: [:]
        )?.first))
        let tableClass = try Self.request(try #require(Self.driver.maintenanceStatements(
            operation: name.tableClass, table: "Orders", schema: nil,
            options: ["choice": String(localized: "Standard-Infrequent Access")]
        )?.first))
        let onDemand = try Self.request(try #require(Self.driver.maintenanceStatements(
            operation: name.onDemand, table: "Orders", schema: nil, options: [:]
        )?.first))

        #expect(recovery["PointInTimeRecoverySpecification"] == .object(["PointInTimeRecoveryEnabled": .bool(false)]))
        #expect(protection["DeletionProtectionEnabled"] == .bool(true))
        #expect(tableClass["TableClass"] == .string("STANDARD_INFREQUENT_ACCESS"))
        #expect(onDemand["BillingMode"] == .string("PAY_PER_REQUEST"))
    }

    @Test("An unknown operation, or one with no table, builds nothing")
    func unknownMaintenance() {
        #expect(Self.driver.maintenanceStatements(operation: "VACUUM", table: "Orders", schema: nil, options: [:]) == nil)
        #expect(Self.driver.maintenanceStatements(
            operation: DynamoDBPluginDriver.MaintenanceName.onDemand, table: nil, schema: nil, options: [:]
        ) == nil)
    }

    // MARK: - Indexes and drop

    @Test("An index edited in place is refused, and so is dropping the primary key or a local index")
    func indexEditsAndDrops() {
        let global = PluginIndexDefinition(name: "byStatus", columns: ["status"], indexType: "GLOBAL All attributes")
        let local = PluginIndexDefinition(name: "byTotal", columns: ["pk", "total"], indexType: "LOCAL Keys only")
        let primary = PluginIndexDefinition(name: "PRIMARY", columns: ["pk"], indexType: "PRIMARY KEY")

        #expect(Self.driver.schemaOperationRefusal(.modifyIndex(old: global, new: global)) != nil)
        #expect(Self.driver.schemaOperationRefusal(.dropIndex(global)) == nil)
        #expect(Self.driver.schemaOperationRefusal(.dropIndex(local)) != nil)
        #expect(Self.driver.schemaOperationRefusal(.dropIndex(primary)) != nil)
    }

    @Test("A global index from the Structure tab takes its keys from the columns and its projection from the included ones")
    func addIndex() throws {
        let index = PluginIndexDefinition(
            name: "byStatus", columns: ["status", "total"], expressions: nil, includedColumns: ["a"],
            ddlMethodAndKeys: nil, ddlWhereClause: nil
        )
        let statement = try #require(Self.driver.generateAddIndexSQL(table: "Orders", index: index))

        let create = try Self.request(statement)["GlobalSecondaryIndexUpdates"]?.arrayValue?.first?["Create"]
        #expect(create?["KeySchema"] == .array([
            .object(["AttributeName": .string("status"), "KeyType": .string("HASH")]),
            .object(["AttributeName": .string("total"), "KeyType": .string("RANGE")])
        ]))
        #expect(create?["Projection"] == .object([
            "ProjectionType": .string("INCLUDE"), "NonKeyAttributes": .array([.string("a")])
        ]))
    }

    @Test("A unique index, or one with more than two columns, is refused with a reason")
    func refusedIndexes() {
        let unique = PluginIndexDefinition(name: "u", columns: ["a"], isUnique: true)
        let wide = PluginIndexDefinition(name: "w", columns: ["a", "b", "c"])

        #expect(Self.driver.generateAddIndexSQL(table: "Orders", index: unique) == nil)
        #expect(Self.driver.generateAddIndexSQL(table: "Orders", index: wide) == nil)
        #expect(Self.driver.schemaOperationRefusal(.addIndex(unique)) != nil)
        #expect(Self.driver.schemaOperationRefusal(.addIndex(wide)) != nil)
    }

    @Test("Dropping an index deletes that global index, and the primary key is never dropped")
    func dropIndex() throws {
        let statement = try #require(Self.driver.generateDropIndexSQL(table: "Orders", indexName: "byStatus"))

        let update = try Self.request(statement)["GlobalSecondaryIndexUpdates"]?.arrayValue?.first
        #expect(update == .object(["Delete": .object(["IndexName": .string("byStatus")])]))
        #expect(Self.driver.generateDropIndexSQL(table: "Orders", indexName: "PRIMARY") == nil)
    }

    @Test("Dropping a table is a DeleteTable request, and only for a valid table name")
    func dropTable() throws {
        let statement = try #require(Self.driver.dropObjectStatement(
            name: "Orders", objectType: "TABLE", schema: nil, cascade: false
        ))

        #expect(try Self.request(statement) == .object(["TableName": .string("Orders")]))
        #expect(Self.driver.dropObjectStatement(name: "Or\"ders", objectType: "TABLE", schema: nil, cascade: false) == nil)
        #expect(Self.driver.dropObjectStatement(name: "Orders", objectType: "VIEW", schema: nil, cascade: false) == nil)
    }

    // MARK: - Field paths

    @Test("Field paths reach into maps up to four levels, and never through a list")
    func fieldPaths() {
        let item: DynamoDBItem = [
            "address": .map(["city": .string("Paris"), "geo": .map(["lat": .map(["deg": .map(["x": .number("1")])])])]),
            "items": .list([.map(["sku": .string("A1")])])
        ]

        let paths = Dictionary(uniqueKeysWithValues: DynamoDBFieldPaths.collect(from: [item]).map { ($0.path, $0) })

        #expect(paths["address.city"]?.typeName == "String")
        #expect(paths["address.geo.lat.deg"]?.depth == 4)
        #expect(paths["address.geo.lat.deg.x"] == nil)
        #expect(paths["items"]?.typeName == "List")
        #expect(paths["items.sku"] == nil)
    }

    // MARK: - Row limits and ORDER BY

    @Test("An injected row limit keeps a smaller one and survives a trailing comment")
    func injectRowLimit() {
        let driver = Self.driver

        let kept = driver.injectRowLimit("SELECT * FROM \"t\" LIMIT 3", limit: 10)
        let commented = driver.injectRowLimit("SELECT * FROM \"t\" -- note", limit: 5)

        #expect(kept?.hasSuffix("\nLIMIT 3") == true)
        #expect(kept?.contains("LIMIT 10") == false)
        #expect(commented?.hasSuffix("-- note\nLIMIT 5") == true)
        #expect(driver.injectRowLimit(#"Scan {"TableName":"t"}"#, limit: 5) == #"Scan {"TableName":"t"} LIMIT 5"#)
        #expect(driver.injectRowLimit("DELETE FROM \"t\" WHERE \"pk\" = 'a'", limit: 5) == nil)
        #expect(driver.injectRowLimit(#"PutItem {"TableName":"t"}"#, limit: 5) == nil)
    }

    @Test("The read limits never go negative and never overflow")
    func readLimits() {
        func limits(_ window: DynamoDBReadWindow, _ cap: Int) -> [Int] {
            let result = DynamoDBPluginDriver.readLimits(window: window, rowCap: cap)
            return [result.wanted, result.read]
        }

        #expect(limits(DynamoDBReadWindow(), 100) == [100, 101])
        #expect(limits(DynamoDBReadWindow(), Int.max) == [Int.max, Int.max])
        #expect(limits(DynamoDBReadWindow(limit: 5), 100) == [5, 5])
        #expect(limits(DynamoDBReadWindow(limit: 500), 100) == [100, 101])
        #expect(limits(DynamoDBReadWindow(limit: -1), 100) == [0, 0])
    }
}

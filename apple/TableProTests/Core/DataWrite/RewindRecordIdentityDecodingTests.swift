//
//  RewindRecordIdentityDecodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct RewindRecordIdentityDecodingTests {
    private func record(identityColumns: [String]?) -> RewindRecord {
        RewindRecord(
            id: UUID(),
            historyId: nil,
            connectionId: UUID(),
            databaseType: .mssql,
            target: DataWriteTarget(database: "shop", schema: "dbo", table: "Ord"),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generatedColumns: ["ID"],
            identityColumns: identityColumns,
            operations: []
        )
    }

    @Test
    func aRecordSavedBeforeIdentityWasKeptDecodesWithNoAnswer() throws {
        let encoded = try JSONEncoder().encode(record(identityColumns: ["ID"]))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "identityColumns")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RewindRecord.self, from: legacy)
        #expect(decoded.identityColumns == nil)
        #expect(decoded.generatedColumns == ["ID"])
    }

    @Test
    func aRecordKeepsItsIdentityColumnsThroughARoundTrip() throws {
        let original = record(identityColumns: ["ID"])
        let decoded = try JSONDecoder().decode(RewindRecord.self, from: JSONEncoder().encode(original))
        #expect(decoded.identityColumns == ["ID"])
    }
}

struct RewindRecordStepDecodingTests {
    private func record() -> RewindRecord {
        let target = DataWriteTarget(database: "shop", schema: nil, table: "users")
        let operation = RowWriteOperation(
            kind: .update,
            target: target,
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            preImage: ["1", "a"],
            postImage: ["1", "b"],
            writtenColumns: ["name"],
            refusal: nil,
            order: 3,
            steps: [
                RowWriteStep(order: 3, columns: [1], before: ["a"], after: ["tmp"]),
                RowWriteStep(order: 5, columns: [1], before: ["tmp"], after: ["b"], afterAbsent: [1])
            ]
        )
        return RewindRecord(
            id: UUID(),
            historyId: nil,
            connectionId: UUID(),
            databaseType: .postgresql,
            target: target,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generatedColumns: [],
            identityColumns: [],
            operations: [operation]
        )
    }

    @Test
    func aRecordSavedBeforeStepsDecodes() throws {
        let encoded = try JSONEncoder().encode(record())
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var operations = try #require(object["operations"] as? [[String: Any]])
        operations[0].removeValue(forKey: "order")
        operations[0].removeValue(forKey: "steps")
        object["operations"] = operations
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RewindRecord.self, from: legacy)
        let operation = try #require(decoded.operations.first)
        #expect(operation.order == nil)
        #expect(operation.steps == nil)
        #expect(operation.postImage == ["1", "b"])
    }

    @Test
    func stepsRoundTrip() throws {
        let original = record()
        let decoded = try JSONDecoder().decode(RewindRecord.self, from: JSONEncoder().encode(original))
        #expect(decoded.operations == original.operations)
    }
}

struct RewindRecordColumnTypeDecodingTests {
    private func record(columnTypeNames: [String: String]?) -> RewindRecord {
        RewindRecord(
            id: UUID(),
            historyId: nil,
            connectionId: UUID(),
            databaseType: .oracle,
            target: DataWriteTarget(database: "FREEPDB1", schema: "APP", table: "ORD"),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generatedColumns: [],
            identityColumns: [],
            columnTypeNames: columnTypeNames,
            operations: []
        )
    }

    @Test
    func aRecordSavedBeforeColumnTypesWereKeptDecodesWithNone() throws {
        let encoded = try JSONEncoder().encode(record(columnTypeNames: ["CREATED": "date"]))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "columnTypeNames")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RewindRecord.self, from: legacy)
        #expect(decoded.columnTypeNames == nil)
        #expect(decoded.identityColumns?.isEmpty == true)
    }

    @Test
    func aRecordKeepsItsColumnTypesThroughARoundTrip() throws {
        let original = record(columnTypeNames: ["CREATED": "date", "NOTE": "nvarchar2"])
        let decoded = try JSONDecoder().decode(RewindRecord.self, from: JSONEncoder().encode(original))
        #expect(decoded.columnTypeNames == ["CREATED": "date", "NOTE": "nvarchar2"])
    }
}

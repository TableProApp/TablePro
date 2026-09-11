//
//  HighlightRuleStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Highlight rule storage")
@MainActor
struct HighlightRuleStorageTests {
    private let directory: URL
    private let connectionId = UUID()

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HighlightRuleStorageTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func scope(table: String, database: String? = "shop", schema: String? = "public") -> TableScope {
        TableScope(connectionId: connectionId, database: database, schema: schema, table: table)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("\(connectionId.uuidString).json")
    }

    @Test("Rules round-trip through a fresh store")
    func roundTrip() {
        let rules = [
            HighlightRule(columnName: "status", value: "paid", color: .green),
            HighlightRule(columnName: "total", filterOperator: .greaterThan, value: "10", color: .red, target: .cell)
        ]
        HighlightRuleStorage(storageDirectory: directory).setRules(rules, for: scope(table: "orders"))

        let reloaded = HighlightRuleStorage(storageDirectory: directory)
        #expect(reloaded.rules(for: scope(table: "orders")) == rules)
        #expect(reloaded.rules(for: scope(table: "customers")).isEmpty)
    }

    @Test("Clearing the last rule removes the connection's file")
    func clearingRemovesFile() {
        let storage = HighlightRuleStorage(storageDirectory: directory)
        storage.setRules([HighlightRule(columnName: "status", value: "paid")], for: scope(table: "orders"))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        storage.setRules([], for: scope(table: "orders"))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("A table rename moves its rules to the new name")
    func renameMovesRules() {
        let storage = HighlightRuleStorage(storageDirectory: directory)
        let rules = [HighlightRule(columnName: "status", value: "paid")]
        storage.setRules(rules, for: scope(table: "orders"))

        storage.renameTable(from: scope(table: "orders"), to: scope(table: "purchases"))

        let reloaded = HighlightRuleStorage(storageDirectory: directory)
        #expect(reloaded.rules(for: scope(table: "orders")).isEmpty)
        #expect(reloaded.rules(for: scope(table: "purchases")) == rules)
    }

    @Test("A schema rename moves every table's rules in it")
    func renameScopeMovesEveryTable() {
        let storage = HighlightRuleStorage(storageDirectory: directory)
        let rules = [HighlightRule(columnName: "status", value: "paid")]
        storage.setRules(rules, for: scope(table: "orders"))
        storage.setRules(rules, for: scope(table: "items"))

        storage.renameContainer(
            connectionId: connectionId, fromDatabase: "shop", fromSchema: "public",
            toDatabase: "shop", toSchema: "sales"
        )

        #expect(storage.rules(for: scope(table: "orders", schema: "sales")) == rules)
        #expect(storage.rules(for: scope(table: "items", schema: "sales")) == rules)
        #expect(storage.rules(for: scope(table: "orders")).isEmpty)
    }

    @Test("Deleting a connection removes its rules")
    func removingConnectionPurges() {
        let storage = HighlightRuleStorage(storageDirectory: directory)
        storage.setRules([HighlightRule(columnName: "status", value: "paid")], for: scope(table: "orders"))

        storage.purgeConnections([connectionId])

        #expect(storage.rules(for: scope(table: "orders")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Deleting a connection removes a set-aside unreadable file too")
    func purgeRemovesUnreadableFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fileURL)
        let storage = HighlightRuleStorage(storageDirectory: directory)
        _ = storage.rules(for: scope(table: "orders"))
        let preserved = directory.appendingPathComponent("\(connectionId.uuidString).unreadable.json")
        #expect(FileManager.default.fileExists(atPath: preserved.path))

        storage.purgeConnections([connectionId])

        #expect(!FileManager.default.fileExists(atPath: preserved.path))
    }

    @Test("Every change moves the observed revision")
    func revisionMoves() {
        let storage = HighlightRuleStorage(storageDirectory: directory)
        let before = storage.revision
        storage.setRules([HighlightRule(columnName: "status", value: "paid")], for: scope(table: "orders"))
        #expect(storage.revision != before)
    }

    @Test("An unreadable file is set aside rather than overwritten")
    func unreadableFileIsPreserved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fileURL)

        let storage = HighlightRuleStorage(storageDirectory: directory)
        #expect(storage.rules(for: scope(table: "orders")).isEmpty)

        let preserved = directory.appendingPathComponent("\(connectionId.uuidString).unreadable.json")
        #expect(FileManager.default.fileExists(atPath: preserved.path))
        #expect(try String(contentsOf: preserved, encoding: .utf8) == "{ not json")
    }

    @Test("A rule the app cannot decode is skipped and the rest survive")
    func undecodableRuleIsSkipped() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = scope(table: "orders").storageComponent
        let json = """
        {"\(key)": [
          {"columnName": "status", "filterOperator": "=", "value": "paid", "color": "green"},
          {"columnName": "status", "filterOperator": "SOUNDS LIKE", "value": "x", "color": "green"},
          {"columnName": "status", "filterOperator": "=", "value": "late", "color": "chartreuse"}
        ]}
        """
        try Data(json.utf8).write(to: fileURL)

        let rules = HighlightRuleStorage(storageDirectory: directory).rules(for: scope(table: "orders"))
        #expect(rules.count == 1)
        #expect(rules.first?.value == "paid")
        #expect(rules.first?.color == .green)
    }
}

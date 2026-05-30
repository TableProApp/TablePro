//
//  BeancountPluginDriverTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Beancount plugin driver")
struct BeancountPluginDriverTests {
    @Test("reloads the SQL projection when an included ledger file changes")
    func reloadsWhenIncludedFileChanges() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beancount-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let included = tempDirectory.appendingPathComponent("accounts.beancount")
        try """
        2024-01-01 open Assets:Bank:Checking USD
        """.write(to: included, atomically: true, encoding: .utf8)

        let ledger = tempDirectory.appendingPathComponent("main.beancount")
        try """
        include "accounts.beancount"
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let driver = BeancountPluginDriver(config: DriverConnectionConfig(
            host: "",
            port: 0,
            username: "",
            password: "",
            database: ledger.path
        ))
        try await driver.connect()
        defer {
            driver.disconnect()
        }

        var result = try await driver.execute(query: "SELECT name FROM accounts ORDER BY name")
        #expect(result.rows.map { $0[0].asText } == ["Assets:Bank:Checking"])

        try """
        2024-01-01 open Assets:Bank:Checking USD
        2024-01-02 open Expenses:Food USD
        """.write(to: included, atomically: true, encoding: .utf8)

        result = try await driver.execute(query: "SELECT name FROM accounts ORDER BY name")
        #expect(result.rows.map { $0[0].asText } == ["Assets:Bank:Checking", "Expenses:Food"])
    }

    @Test("reloads the SQL projection when a glob include matches a new file")
    func reloadsWhenGlobIncludeMatchesNewFile() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beancount-driver-glob-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let imports = tempDirectory.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        try """
        2024-01-01 open Assets:Bank:Checking USD
        """.write(to: imports.appendingPathComponent("accounts.beancount"), atomically: true, encoding: .utf8)

        let ledger = tempDirectory.appendingPathComponent("main.beancount")
        try """
        include "imports/*.beancount"
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let driver = BeancountPluginDriver(config: DriverConnectionConfig(
            host: "",
            port: 0,
            username: "",
            password: "",
            database: ledger.path
        ))
        try await driver.connect()
        defer {
            driver.disconnect()
        }

        var result = try await driver.execute(query: "SELECT name FROM accounts ORDER BY name")
        #expect(result.rows.map { $0[0].asText } == ["Assets:Bank:Checking"])

        try """
        2024-01-02 open Expenses:Food USD
        """.write(to: imports.appendingPathComponent("expenses.beancount"), atomically: true, encoding: .utf8)

        result = try await driver.execute(query: "SELECT name FROM accounts ORDER BY name")
        #expect(result.rows.map { $0[0].asText } == ["Assets:Bank:Checking", "Expenses:Food"])
    }

    @Test("rejects write queries")
    func rejectsWriteQueries() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beancount-driver-read-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let ledger = tempDirectory.appendingPathComponent("main.beancount")
        try """
        2024-01-01 open Assets:Bank:Checking USD
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let driver = BeancountPluginDriver(config: DriverConnectionConfig(
            host: "",
            port: 0,
            username: "",
            password: "",
            database: ledger.path
        ))
        try await driver.connect()
        defer {
            driver.disconnect()
        }

        await #expect(throws: BeancountDriverError.self) {
            _ = try await driver.execute(query: "DELETE FROM accounts")
        }
    }

    @Test("executes BQL queries through the rustledger helper")
    func executesBQLQueriesThroughRustledgerHelper() async throws {
        let rustledger = try #require(Self.bundledRustledgerPath() ?? Self.installedRustledgerPath())
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beancount-driver-bql-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            unsetenv("TABLEPRO_RUSTLEDGER_BINARY")
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let ledger = tempDirectory.appendingPathComponent("main.beancount")
        try """
        2024-01-01 open Assets:Bank:Checking USD
        2024-01-01 open Expenses:Food USD
        2024-01-01 open Income:Salary USD
        """.write(to: ledger, atomically: true, encoding: .utf8)

        setenv("TABLEPRO_RUSTLEDGER_BINARY", rustledger, 1)

        let driver = BeancountPluginDriver(config: DriverConnectionConfig(
            host: "",
            port: 0,
            username: "",
            password: "",
            database: ledger.path
        ))
        try await driver.connect()
        defer {
            driver.disconnect()
        }

        let result = try await driver.execute(query: "BQL: SELECT account FROM accounts ORDER BY account")

        #expect(result.columns == ["account"])
        #expect(result.rows.map { $0.first?.asText } == [
            "Assets:Bank:Checking",
            "Expenses:Food",
            "Income:Salary"
        ])

        let count = try await driver.fetchRowCount(query: "BQL: SELECT account FROM accounts ORDER BY account")
        #expect(count == 3)

        let page = try await driver.fetchRows(
            query: "BQL: SELECT account FROM accounts ORDER BY account",
            offset: 1,
            limit: 1
        )
        #expect(page.rows.map { $0.first?.asText } == ["Expenses:Food"])
    }

    private static func installedRustledgerPath() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["TABLEPRO_RUSTLEDGER_BINARY"],
            "/opt/homebrew/bin/rledger",
            "/usr/local/bin/rledger"
        ].compactMap { $0 }

        return candidates.first { path in
            FileManager.default.isExecutableFile(atPath: path)
        }
    }

    private static func bundledRustledgerPath() -> String? {
        guard let path = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("BeancountDriver.tableplugin")
            .appendingPathComponent("Contents/Resources/rledger")
            .path else {
            return nil
        }

        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

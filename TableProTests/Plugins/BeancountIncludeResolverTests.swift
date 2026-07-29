//
//  BeancountIncludeResolverTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("Beancount include resolver")
struct BeancountIncludeResolverTests {
    @Test("collects the main ledger and every included file")
    func resolvesIncludes() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try "2024-01-02 price USD 1.35 CAD\n"
            .write(to: directory.appendingPathComponent("prices.beancount"), atomically: true, encoding: .utf8)

        let ledger = directory.appendingPathComponent("main.beancount")
        try """
        include "prices.beancount"

        2024-01-01 open Assets:Bank:Checking USD
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let graph = try BeancountIncludeResolver().resolve(fileURL: ledger)

        #expect(graph.sourceFiles.map(\.lastPathComponent).sorted() == ["main.beancount", "prices.beancount"])
    }

    @Test("expands glob includes and watches their directories")
    func resolvesGlobIncludes() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imports = directory.appendingPathComponent("imports", isDirectory: true)
        let nested = imports.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try "2024-01-01 open Assets:Bank:Checking USD\n"
            .write(to: imports.appendingPathComponent("accounts.beancount"), atomically: true, encoding: .utf8)
        try "2024-01-01 open Expenses:Food USD\n"
            .write(to: nested.appendingPathComponent("expenses.beancount"), atomically: true, encoding: .utf8)

        let ledger = directory.appendingPathComponent("main.beancount")
        try """
        include "imports/*.beancount"
        include "imports/**/*.beancount"
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let graph = try BeancountIncludeResolver().resolve(fileURL: ledger)

        #expect(graph.sourceFiles.map(\.lastPathComponent).sorted() == [
            "accounts.beancount",
            "expenses.beancount",
            "main.beancount"
        ])
        #expect(graph.watchedDirectories.map(\.lastPathComponent).contains("imports"))
        #expect(graph.watchedDirectories.map(\.lastPathComponent).contains("nested"))
    }

    @Test("detects include cycles instead of looping")
    func detectsIncludeCycle() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.beancount")
        let second = directory.appendingPathComponent("second.beancount")
        try "include \"second.beancount\"\n".write(to: first, atomically: true, encoding: .utf8)
        try "include \"first.beancount\"\n".write(to: second, atomically: true, encoding: .utf8)

        #expect(throws: BeancountResolverError.self) {
            _ = try BeancountIncludeResolver().resolve(fileURL: first)
        }
    }

    @Test("ignores filesystem-root glob includes")
    func ignoresRootGlobIncludes() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = directory.appendingPathComponent("main.beancount")
        try """
        include "/*.beancount"

        2024-01-01 open Assets:Bank:Checking USD
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let graph = try BeancountIncludeResolver().resolve(fileURL: ledger)

        #expect(graph.sourceFiles.map(\.lastPathComponent) == ["main.beancount"])
    }

    private static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beancount-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

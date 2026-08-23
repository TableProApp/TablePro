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

    @Test("tracks missing documents relative to their declaring source")
    func resolvesIncludedDocumentDependencies() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let parts = directory.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)

        let absoluteDocument = directory.appendingPathComponent("absolute.pdf").standardizedFileURL
        let linkedDocument = parts.appendingPathComponent("linked.pdf").standardizedFileURL
        let linkedTarget = directory.appendingPathComponent("external.pdf").standardizedFileURL
        try FileManager.default.createSymbolicLink(
            atPath: linkedDocument.path,
            withDestinationPath: linkedTarget.path
        )
        let included = parts.appendingPathComponent("entries.beancount")
        try """
        2024/1/2 document Assets:Cash "receipt.pdf"
        2024-01-03 document Assets:Cash "\(absoluteDocument.path)"
        2024-01-04 document Assets:Cash "tab\\treceipt.pdf"
        2024-01-05 document Assets:Cash "linked.pdf"
        """.write(to: included, atomically: true, encoding: .utf8)

        let ledger = directory.appendingPathComponent("main.beancount")
        try """
        include\t"parts/entries.beancount"

        2024-01-01 open Assets:Cash USD
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let graph = try BeancountIncludeResolver().resolve(fileURL: ledger)
        let relativeDocument = parts.appendingPathComponent("receipt.pdf").standardizedFileURL
        let escapedDocument = parts.appendingPathComponent("tab\treceipt.pdf").standardizedFileURL

        #expect(graph.reloadDependencies.contains(relativeDocument))
        #expect(graph.reloadDependencies.contains(absoluteDocument))
        #expect(graph.reloadDependencies.contains(escapedDocument))
        #expect(graph.reloadDependencies.contains(linkedDocument))
        #expect(graph.reloadDependencies.contains(linkedTarget))
        #expect(!graph.sourceFiles.contains(relativeDocument))
        #expect(!graph.sourceFiles.contains(absoluteDocument))
    }

    @Test("bounds document symlink dependency resolution")
    func boundsDocumentSymlinkDependencies() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<40 {
            try FileManager.default.createSymbolicLink(
                atPath: directory.appendingPathComponent("link-\(index).pdf").path,
                withDestinationPath: "link-\(index + 1).pdf"
            )
        }

        let ledger = directory.appendingPathComponent("main.beancount")
        try "2024-01-01 document Assets:Cash \"link-0.pdf\"\n"
            .write(to: ledger, atomically: true, encoding: .utf8)

        let graph = try BeancountIncludeResolver().resolve(fileURL: ledger)
        let linkedDependencies = graph.reloadDependencies.filter {
            $0.deletingLastPathComponent() == directory.standardizedFileURL
                && $0.lastPathComponent.hasPrefix("link-")
        }

        #expect(linkedDependencies.count <= 34)
        #expect(graph.reloadDependencies.contains(directory.appendingPathComponent("link-32.pdf")))
        #expect(!graph.reloadDependencies.contains(directory.appendingPathComponent("link-33.pdf")))
    }

    @Test("applies document roots after traversing every include")
    func resolvesDocumentRootDependencies() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let parts = directory.appendingPathComponent("parts", isDirectory: true)
        let relativeRoot = directory.appendingPathComponent("archive", isDirectory: true)
        let nestedRoot = relativeRoot.appendingPathComponent("account/nested", isDirectory: true)
        let absoluteRoot = directory.appendingPathComponent("absolute-archive", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: absoluteRoot, withIntermediateDirectories: true)

        try "2024-01-02 document Assets:Cash \"receipt.pdf\"\n"
            .write(to: parts.appendingPathComponent("entries.beancount"), atomically: true, encoding: .utf8)
        try """
        option\t"documents"\t"archive"
        option "documents" "\(absoluteRoot.path)"
        """.write(
            to: parts.appendingPathComponent("options.beancount"),
            atomically: true,
            encoding: .utf8
        )

        let ledger = directory.appendingPathComponent("main.beancount")
        try """
        include "parts/entries.beancount"
        include "parts/options.beancount"
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let graph = try BeancountIncludeResolver().resolve(fileURL: ledger)
        let candidates = [
            relativeRoot.appendingPathComponent("receipt.pdf").standardizedFileURL,
            absoluteRoot.appendingPathComponent("receipt.pdf").standardizedFileURL
        ]

        for candidate in candidates {
            #expect(graph.reloadDependencies.contains(candidate))
            #expect(!graph.sourceFiles.contains(candidate))
        }
        #expect(graph.reloadDependencies.contains(parts.appendingPathComponent("receipt.pdf").standardizedFileURL))
        #expect(!graph.reloadDependencies.contains(relativeRoot.standardizedFileURL))
        #expect(!graph.reloadDependencies.contains(nestedRoot.standardizedFileURL))
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

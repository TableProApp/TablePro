//
//  PostgreSQLDumpToolLocatorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("PostgreSQLDumpToolLocator")
struct PostgreSQLDumpToolLocatorTests {
    private func makeInstall(root: URL, name: String, binary: String, fileManager: FileManager) throws {
        let bin = root.appendingPathComponent("\(name)/bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent(binary)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    }

    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pg-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Only postgresql and libpq installs count under an opt root")
    func filtersOptRootEntries() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let optRoot = base.appendingPathComponent("opt", isDirectory: true)
        for name in ["postgresql@14", "libpq", "libpq@18", "mysql-client", "redis"] {
            try makeInstall(root: optRoot, name: name, binary: "pg_dump", fileManager: .default)
        }

        let found = PostgreSQLDumpToolLocator.installedPaths(binary: "pg_dump", roots: [optRoot.path])
        #expect(found.map { URL(fileURLWithPath: $0).pathComponents.dropLast(2).last } == ["libpq", "libpq@18", "postgresql@14"])
    }

    @Test("Every entry counts under a versioned root that is not an opt directory")
    func keepsVersionedRootEntries() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let versions = base.appendingPathComponent("Versions", isDirectory: true)
        for name in ["13", "17"] {
            try makeInstall(root: versions, name: name, binary: "pg_dump", fileManager: .default)
        }

        let found = PostgreSQLDumpToolLocator.installedPaths(binary: "pg_dump", roots: [versions.path])
        #expect(found.count == 2)
    }

    @Test("Roots are searched in order and a symlinked duplicate is listed once")
    func dedupesSymlinkedInstall() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("opt", isDirectory: true)
        let second = base.appendingPathComponent("Versions", isDirectory: true)
        try makeInstall(root: first, name: "postgresql@17", binary: "pg_dump", fileManager: .default)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: second.appendingPathComponent("latest"),
            withDestinationURL: first.appendingPathComponent("postgresql@17")
        )

        let found = PostgreSQLDumpToolLocator.installedPaths(binary: "pg_dump", roots: [first.path, second.path])
        #expect(found.count == 1)
        #expect(found.first?.hasPrefix(first.path) == true)
    }

    @Test("With no server version the PATH binary is taken as it always was")
    func unknownServerTakesPathBinary() {
        let selection = PostgreSQLDumpToolLocator.select(
            binary: "pg_dump",
            serverVersion: nil,
            roots: [],
            pathBinary: { _ in "/usr/bin/pg_dump" },
            probe: { _ in .known(PostgreSQLServerVersion(number: 170_011)) }
        )
        #expect(selection == .found(path: "/usr/bin/pg_dump"))
    }

    @Test("Nothing installed is missing, not incompatible")
    func nothingInstalledIsMissing() {
        let selection = PostgreSQLDumpToolLocator.select(
            binary: "pg_dump",
            serverVersion: "9.1.24",
            roots: [],
            pathBinary: { _ in nil },
            probe: { _ in .unknown }
        )
        #expect(selection == .missing)
    }

    @Test("An installed tool that cannot reach the server is incompatible, and the message names both")
    func incompatibleNamesTheVersions() {
        let selection = PostgreSQLDumpToolLocator.select(
            binary: "pg_dump",
            serverVersion: "9.1.24",
            roots: [],
            pathBinary: { _ in "/opt/homebrew/bin/pg_dump" },
            probe: { _ in .known(PostgreSQLServerVersion(number: 170_011)) }
        )
        guard case .incompatible(let message) = selection else {
            Issue.record("expected an incompatible selection, got \(selection)")
            return
        }
        #expect(message.contains("PostgreSQL 9.1"))
        #expect(message.contains("pg_dump 9.3 to 14"))
        #expect(message.contains("17.11"))
    }

    @Test("A binary whose version cannot be read is used rather than hidden")
    func unreadableVersionIsStillUsed() {
        let selection = PostgreSQLDumpToolLocator.select(
            binary: "pg_dump",
            serverVersion: "9.1.24",
            roots: [],
            pathBinary: { _ in "/usr/local/bin/pg_dump" },
            probe: { _ in .unknown }
        )
        #expect(selection == .found(path: "/usr/local/bin/pg_dump"))
    }

    @Test("A compatible install beats both the PATH binary and an unreadable one")
    func compatibleInstallWins() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let optRoot = base.appendingPathComponent("opt", isDirectory: true)
        try makeInstall(root: optRoot, name: "postgresql@14", binary: "pg_dump", fileManager: .default)
        try makeInstall(root: optRoot, name: "postgresql@12", binary: "pg_dump", fileManager: .default)

        let selection = PostgreSQLDumpToolLocator.select(
            binary: "pg_dump",
            serverVersion: "9.1.24",
            roots: [optRoot.path],
            pathBinary: { _ in "/opt/homebrew/bin/pg_dump" },
            probe: { path in
                if path.contains("postgresql@14") { return .known(PostgreSQLServerVersion(number: 140_013)) }
                if path.contains("postgresql@12") { return .known(PostgreSQLServerVersion(number: 120_022)) }
                return .known(PostgreSQLServerVersion(number: 170_011))
            }
        )
        #expect(selection == .found(path: "\(optRoot.path)/postgresql@14/bin/pg_dump"))
    }

    @Test("pg_restore is matched to the server by the same rule as pg_dump")
    func restoreBinaryFollowsTheSameRule() {
        let selection = PostgreSQLDumpToolLocator.select(
            binary: "pg_restore",
            serverVersion: "9.1.24",
            roots: [],
            pathBinary: { _ in "/opt/homebrew/bin/pg_restore" },
            probe: { _ in .known(PostgreSQLServerVersion(number: 170_011)) }
        )
        guard case .incompatible(let message) = selection else {
            Issue.record("expected an incompatible selection, got \(selection)")
            return
        }
        #expect(message.contains("pg_restore"))
        #expect(!message.contains("pg_dump"))
    }

    @Test("A probe that never answers is abandoned rather than left to hang")
    func versionProbeTimesOut() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let script = base.appendingPathComponent("hang.sh")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let started = Date()
        let probed = PostgreSQLDumpToolLocator.probeVersion(of: script.path, timeout: 0.5)
        #expect(probed == .unknown)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

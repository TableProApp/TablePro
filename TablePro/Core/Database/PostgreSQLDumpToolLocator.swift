//
//  PostgreSQLDumpToolLocator.swift
//  TablePro
//

import Foundation
import os

enum PostgreSQLDumpToolLocator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PostgreSQLDumpToolLocator")

    static let versionProbeTimeout: TimeInterval = 3

    static let searchRoots = [
        "/opt/homebrew/opt",
        "/usr/local/opt",
        "/Applications/Postgres.app/Contents/Versions",
        "/Library/PostgreSQL"
    ]

    /// What a probed binary reported. A binary whose `--version` cannot be read or parsed is
    /// `unknown`: it is used when nothing better is found, because refusing it would hide a tool
    /// that worked before any of this existed.
    enum ProbedVersion: Equatable, Sendable {
        case known(PostgreSQLServerVersion)
        case unknown
    }

    static func select(
        binary: String,
        serverVersion: String?,
        roots: [String] = searchRoots,
        fileManager: FileManager = .default,
        pathBinary: (String) -> String? = { CLIExecutableFinder.findExecutable($0) },
        probe: (String) -> ProbedVersion = { probeVersion(of: $0) }
    ) -> NativeDumpToolSelection {
        let preferredPath = pathBinary(binary)
        guard let server = PostgreSQLServerVersion(serverVersion) else {
            return preferredPath.map { .found(path: $0) } ?? .missing
        }

        var preferred: PostgreSQLDumpToolCompatibility.Candidate?
        var unknownVersionPaths: [String] = []
        if let preferredPath {
            switch probe(preferredPath) {
            case .known(let version):
                preferred = .init(path: preferredPath, version: version)
            case .unknown:
                unknownVersionPaths.append(preferredPath)
            }
        }
        if let preferred, PostgreSQLDumpToolCompatibility.canDump(server: server, with: preferred.version) {
            return chosen(path: preferred.path, version: preferred.version, server: server, binary: binary)
        }

        let preferredResolved = preferredPath.map { resolvedPath($0) }
        var others: [PostgreSQLDumpToolCompatibility.Candidate] = []
        for path in installedPaths(binary: binary, roots: roots, fileManager: fileManager)
        where resolvedPath(path) != preferredResolved {
            switch probe(path) {
            case .known(let version):
                others.append(.init(path: path, version: version))
            case .unknown:
                unknownVersionPaths.append(path)
            }
        }

        if let choice = PostgreSQLDumpToolCompatibility.choose(for: server, preferred: nil, others: others) {
            return chosen(path: choice.path, version: choice.version, server: server, binary: binary)
        }
        if let fallback = unknownVersionPaths.first {
            logger.warning(
                """
                \(binary, privacy: .public) at \(fallback, privacy: .public) reports no readable version; \
                using it for a \(server.majorReleaseName, privacy: .public) server
                """
            )
            return .found(path: fallback)
        }

        let found = ([preferred].compactMap { $0 }) + others
        guard !found.isEmpty else { return .missing }
        return .incompatible(
            PostgreSQLDumpToolCompatibility.refusal(for: server, found: found, toolName: binary)
        )
    }

    static func installedPaths(
        binary: String,
        roots: [String] = searchRoots,
        fileManager: FileManager = .default
    ) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() where isPostgreSQLInstall(entry, under: root) {
                let path = "\(root)/\(entry)/bin/\(binary)"
                guard fileManager.isExecutableFile(atPath: path) else { continue }
                guard seen.insert(resolvedPath(path)).inserted else { continue }
                paths.append(path)
            }
        }
        return paths
    }

    static func probeVersion(of path: String, timeout: TimeInterval = versionProbeTimeout) -> ProbedVersion {
        guard let output = versionOutput(of: path, timeout: timeout),
              let version = PostgreSQLServerVersion(output) else {
            return .unknown
        }
        return .known(version)
    }

    private static func chosen(
        path: String,
        version: PostgreSQLServerVersion,
        server: PostgreSQLServerVersion,
        binary: String
    ) -> NativeDumpToolSelection {
        logger.info(
            """
            \(binary, privacy: .public) \(version.fullName, privacy: .public) at \(path, privacy: .public) \
            for a PostgreSQL \(server.fullName, privacy: .public) server
            """
        )
        return .found(path: path)
    }

    private static func isPostgreSQLInstall(_ entry: String, under root: String) -> Bool {
        guard root.hasSuffix("/opt") else { return true }
        return entry.hasPrefix("postgresql") || entry.hasPrefix("libpq")
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func versionOutput(of path: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = CLIToolEnvironment.augmented()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            logger.warning("\(path, privacy: .public) did not answer --version within \(timeout, privacy: .public)s")
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

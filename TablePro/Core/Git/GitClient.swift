//
//  GitClient.swift
//  TablePro
//

import Foundation
import os

internal struct GitCommandFailure: LocalizedError, Equatable {
    let exitCode: Int32
    let message: String

    var errorDescription: String? {
        message.isEmpty ? String(format: String(localized: "Git exited with status %d."), exitCode) : message
    }
}

internal struct GitClient: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "GitClient")

    let runner: GitProcessRunner

    static func make(locator: GitExecutableLocator = .system) -> GitClient? {
        locator.locate().map { GitClient(runner: GitProcessRunner(executableURL: $0)) }
    }

    func repositoryInfo(in directory: URL) async throws -> GitRepositoryInfo? {
        let result = try await runner.run(.repositoryInfo(in: directory))
        guard result.succeeded else {
            Self.logger.debug("Not a work tree: \(result.errorMessage, privacy: .private)")
            return nil
        }
        return GitRepositoryInfoParser.parse(result.standardOutput)
    }

    func hasCommits(in directory: URL) async throws -> Bool {
        try await headCommit(in: directory) != nil
    }

    func headCommit(in directory: URL) async throws -> String? {
        let result = try await runner.run(.verifyHead(in: directory))
        guard result.succeeded else { return nil }
        return (String(bytes: result.standardOutput, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func status(in directory: URL, pathspec: String = ".") async throws -> [GitStatusRecord] {
        let result = try await runner.run(.status(in: directory, pathspec: pathspec))
        guard result.succeeded else { throw failure(result) }
        return GitStatusParser.parse(result.standardOutput)
    }

    func trackedFiles(in directory: URL) async throws -> [String] {
        let result = try await runner.run(.trackedFiles(in: directory))
        guard result.succeeded else { throw failure(result) }
        return GitOutputTokens.split(result.standardOutput, separator: 0).filter { !$0.isEmpty }
    }

    func history(of fileURL: URL, limit: Int) async throws -> [GitCommitRecord] {
        let result = try await runner.run(.fileHistory(of: fileURL, limit: limit))
        guard result.succeeded else { throw failure(result) }
        return GitLogParser.parse(result.standardOutput)
    }

    func blob(revision: String, path: String, in directory: URL) async throws -> Data {
        let result = try await runner.run(.blob(revision: revision, path: path, in: directory))
        guard result.succeeded else { throw failure(result) }
        return result.standardOutput
    }

    private func failure(_ result: GitProcessResult) -> GitCommandFailure {
        GitCommandFailure(exitCode: result.exitCode, message: result.errorMessage)
    }
}

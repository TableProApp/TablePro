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

internal struct GitUpstreamDivergence: Equatable, Sendable {
    let ahead: Int
    let behind: Int

    var hasDiverged: Bool { ahead > 0 && behind > 0 }
}

internal struct GitPullDiverged: Error, Equatable {
    let output: String
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

    func currentBranch(in directory: URL) async throws -> String? {
        let result = try await runner.run(.currentBranch(in: directory))
        guard result.succeeded else { return nil }
        let name = (String(bytes: result.standardOutput, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func upstreamDivergence(in directory: URL) async throws -> GitUpstreamDivergence? {
        let result = try await runner.run(.upstreamDivergence(in: directory))
        guard result.succeeded else { return nil }
        let counts = (String(bytes: result.standardOutput, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }
        guard counts.count == 2 else { return nil }
        return GitUpstreamDivergence(ahead: counts[0], behind: counts[1])
    }

    func changedPaths(from oldCommit: String, to newCommit: String, in directory: URL) async throws -> [String] {
        let result = try await runner.run(.changedPaths(from: oldCommit, to: newCommit, in: directory))
        guard result.succeeded else { throw failure(result) }
        return GitOutputTokens.split(result.standardOutput, separator: 0).filter { !$0.isEmpty }
    }

    // Commits the working-tree state of `paths` only and keeps whatever else is staged in the index.
    // `commit --only` reaches every tracked path itself; an untracked one has to be added first.
    func commit(_ paths: [String], adding untrackedPaths: [String] = [], message: String, in directory: URL) async throws {
        guard !paths.isEmpty else { return }
        if !untrackedPaths.isEmpty {
            let staged = try await runner.run(.stage(untrackedPaths, in: directory))
            guard staged.succeeded else { throw writeFailure(staged) }
        }
        let committed = try await runner.run(.commit(paths, message: message, in: directory))
        guard committed.succeeded else { throw writeFailure(committed) }
    }

    func pull(in directory: URL) async throws {
        let result = try await runner.run(.pull(in: directory))
        guard !result.succeeded else { return }
        let failure = writeFailure(result)
        if let divergence = try? await upstreamDivergence(in: directory), divergence.hasDiverged {
            throw GitPullDiverged(output: failure.message)
        }
        throw failure
    }

    func push(in directory: URL) async throws {
        let result = try await runner.run(.push(in: directory))
        guard result.succeeded else { throw writeFailure(result) }
    }

    private func failure(_ result: GitProcessResult) -> GitCommandFailure {
        GitCommandFailure(exitCode: result.exitCode, message: result.errorMessage)
    }

    private func writeFailure(_ result: GitProcessResult) -> GitCommandFailure {
        GitCommandFailure(exitCode: result.exitCode, message: result.combinedOutput)
    }
}

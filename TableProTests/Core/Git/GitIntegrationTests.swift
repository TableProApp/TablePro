//
//  GitIntegrationTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

private struct ScratchRepository {
    let root: URL
    let client: GitClient

    init(client: GitClient) throws {
        self.client = client
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-git-tests")
            .appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    func write(_ text: String, to relativePath: String) throws {
        let url = url(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    @discardableResult
    func git(_ arguments: String...) async throws -> GitProcessResult {
        let identity = [
            "-c", "user.name=Ann Author", "-c", "user.email=ann@example.com",
            "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main",
        ]
        let result = try await client.runner.run(GitCommand(arguments: identity + arguments, workingDirectory: root))
        guard result.succeeded else { throw GitCommandFailure(exitCode: result.exitCode, message: result.errorMessage) }
        return result
    }

    func indexIdentity() throws -> [FileAttributeKey: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url(".git/index").path)
        return [
            .systemFileNumber: attributes[.systemFileNumber] ?? 0,
            .modificationDate: attributes[.modificationDate] ?? Date.distantPast,
        ]
    }
}

@Suite("Git against a real repository", .enabled(if: GitClient.make() != nil), .serialized)
struct GitIntegrationTests {
    private let client: GitClient

    init() throws {
        client = try #require(GitClient.make())
    }

    @Test("Status from a linked subfolder maps paths into the folder and never writes the index")
    func statusFromSubfolder() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try repo.write("SELECT 1;\n", to: "sql queries/a b.sql")
        try repo.write("SELECT 2;\n", to: "sql queries/clean.sql")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try repo.write("SELECT 10;\n", to: "sql queries/a b.sql")
        try repo.write("new\n", to: "sql queries/日本.sql")
        try repo.write("elsewhere\n", to: "other/x.sql")
        try await Task.sleep(for: .milliseconds(1_100))
        let before = try repo.indexIdentity()

        let folder = repo.url("sql queries")
        let info = try #require(try await client.repositoryInfo(in: folder))
        let records = try await client.status(in: folder)
        let statuses = LinkedFolderGitStatusStore.folderRelativeStatuses(records, prefix: info.prefix)

        let tracked = LinkedFolderGitStatusStore.folderRelativePaths(
            try await client.trackedFiles(in: folder),
            prefix: info.prefix
        )
        #expect(tracked == ["a b.sql", "clean.sql"])
        #expect(info.prefix == "sql queries/")
        #expect(statuses["a b.sql"]?.canDiscardChanges == true)
        #expect(statuses["日本.sql"]?.isUntracked == true)
        #expect(statuses["clean.sql"] == nil)
        #expect(statuses.count == 2)
        let after = try repo.indexIdentity()
        #expect(before[.systemFileNumber] as? Int == after[.systemFileNumber] as? Int)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    }

    @Test("A folder outside any repository is not one")
    func notARepository() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try repo.write("SELECT 1;\n", to: "q.sql")

        #expect(try await client.repositoryInfo(in: repo.root) == nil)
        await #expect(throws: VersionHistoryError.notInRepository) {
            try await LinkedFileVersionHistoryProvider(fileURL: repo.url("q.sql")).loadHistory()
        }
    }

    @Test("History follows a rename, reads each version, and restores one into the current file")
    func historyAcrossRename() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try repo.write("v1\n", to: "q/old name.sql")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "add")
        try repo.write("v2\n", to: "q/old name.sql")
        try await repo.git("commit", "-qam", "second")
        try await repo.git("mv", "q/old name.sql", "q/new name.sql")
        try await repo.git("commit", "-qm", "rename")
        try repo.write("v3\n", to: "q/new name.sql")
        try await repo.git("commit", "-qam", "third")
        try repo.write("working\n", to: "q/new name.sql")

        let provider = LinkedFileVersionHistoryProvider(fileURL: repo.url("q/new name.sql"))
        let page = try await provider.loadHistory()

        #expect(page.entries.first?.isCurrent == true)
        #expect(page.entries.first?.hasUncommittedChanges == true)
        #expect(page.entries.dropFirst().compactMap(\.summary) == ["third", "rename", "second", "add"])
        #expect(page.notice == nil)
        let oldest = try #require(page.entries.last)
        #expect(try await provider.content(of: oldest.reference) == "v1\n")
        #expect(try await provider.content(of: .current) == "working\n")

        let plan = try await provider.prepareRestore(oldest.reference)
        #expect(plan.replacesUncommittedChanges)
        try await plan.apply()

        #expect(try repo.read("q/new name.sql") == "v1\n")
        #expect(FileManager.default.fileExists(atPath: repo.url("q/old name.sql").path) == false)
    }

    @Test("Discard puts back the staged text, keeps the stage, and leaves an unstaged-only file at its commit")
    func discardKeepsStagedChanges() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try repo.write("committed\n", to: "staged.sql")
        try repo.write("committed\n", to: "plain.sql")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try repo.write("staged\n", to: "staged.sql")
        try await repo.git("add", "staged.sql")
        try repo.write("unstaged\n", to: "staged.sql")
        try repo.write("unstaged\n", to: "plain.sql")

        try await LinkedFileVersionHistoryProvider(fileURL: repo.url("staged.sql")).prepareDiscard().apply()
        try await LinkedFileVersionHistoryProvider(fileURL: repo.url("plain.sql")).prepareDiscard().apply()

        #expect(try repo.read("staged.sql") == "staged\n")
        #expect(try repo.read("plain.sql") == "committed\n")
        let records = try await client.status(in: repo.root)
        let staged = try #require(records.first { $0.path == "staged.sql" })
        #expect(staged.status == GitFileStatus(staged: .modified, unstaged: .unmodified))
        #expect(records.contains { $0.path == "plain.sql" } == false)
    }

    @Test("A repository with no commits shows only the current version")
    func unbornRepository() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try repo.write("SELECT 1;\n", to: "q.sql")

        let page = try await LinkedFileVersionHistoryProvider(fileURL: repo.url("q.sql")).loadHistory()

        #expect(page.entries.count == 1)
        #expect(page.entries.first?.isCurrent == true)
        #expect(page.entries.first?.hasUncommittedChanges == true)
    }

    @Test("A deleted file reports that it is gone")
    func missingFile() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")

        await #expect(throws: VersionHistoryError.subjectNotFound) {
            try await LinkedFileVersionHistoryProvider(fileURL: repo.url("gone.sql")).loadHistory()
        }
    }

    @Test("A write that finds the file changed since it was prepared replaces nothing")
    func restoreRefusesAFileThatChanged() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try repo.write("v1\n", to: "q.sql")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try repo.write("v2\n", to: "q.sql")
        try await repo.git("commit", "-qam", "second")
        let provider = LinkedFileVersionHistoryProvider(fileURL: repo.url("q.sql"))
        let first = try #require(try await provider.loadHistory().entries.last)

        let plan = try await provider.prepareRestore(first.reference)
        #expect(!plan.replacesUncommittedChanges)
        try repo.write("edited meanwhile\n", to: "q.sql")

        await #expect(throws: VersionHistoryError.fileChangedBeforeWriting) { try await plan.apply() }
        #expect(try repo.read("q.sql") == "edited meanwhile\n")
    }

    @Test("A file git is told to ignore changes to still counts as changed when its bytes differ")
    func assumeUnchangedStillAsks() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try repo.write("v1\n", to: "q.sql")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try await repo.git("update-index", "--assume-unchanged", "q.sql")
        try repo.write("local edit\n", to: "q.sql")
        let provider = LinkedFileVersionHistoryProvider(fileURL: repo.url("q.sql"))
        let first = try #require(try await provider.loadHistory().entries.last)

        let plan = try await provider.prepareRestore(first.reference)

        #expect(plan.replacesUncommittedChanges)
    }

    @Test("A Git LFS pointer is never written over the file")
    func largeFileStoragePointerIsRefused() {
        let pointer = Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 12\n".utf8)
        #expect(throws: VersionHistoryError.storedInLargeFileStorage) {
            try LinkedFileVersionHistoryProvider.rejectLargeFileStoragePointer(pointer)
        }
        #expect(throws: Never.self) {
            try LinkedFileVersionHistoryProvider.rejectLargeFileStoragePointer(Data("SELECT 1;\n".utf8))
        }
    }

    @Test("Discard writes nothing when the staged version changed after it was prepared")
    func discardRefusesAChangedIndex() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try repo.write("committed\n", to: "q.sql")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try repo.write("edited\n", to: "q.sql")
        let plan = try await LinkedFileVersionHistoryProvider(fileURL: repo.url("q.sql")).prepareDiscard()

        try await repo.git("add", "q.sql")

        await #expect(throws: VersionHistoryError.fileChangedBeforeWriting) { try await plan.apply() }
        #expect(try repo.read("q.sql") == "edited\n")
    }
}

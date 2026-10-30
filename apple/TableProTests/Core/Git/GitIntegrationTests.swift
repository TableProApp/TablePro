//
//  GitIntegrationTests.swift
//  TableProTests
//

import Foundation
import TableProTestSupport
import Testing

@testable import TablePro
@testable import TableProUtilities

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

    init(client: GitClient, root: URL) {
        self.client = client
        self.root = root
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

    // Setup is the test's own Terminal git, which clones and pushes; the app's reads reach no remote.
    @discardableResult
    func git(_ arguments: String...) async throws -> GitProcessResult {
        let identity = [
            "-c", "user.name=Ann Author", "-c", "user.email=ann@example.com",
            "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main",
        ]
        let result = try await client.runner.run(
            GitCommand(arguments: identity + arguments, workingDirectory: root, access: .write)
        )
        guard result.succeeded else { throw GitCommandFailure(exitCode: result.exitCode, message: result.errorMessage) }
        return result
    }

    // Write commands read identity, signing and hooks from config, as Terminal git does.
    func configureForWrites() async throws {
        try await git("config", "user.name", "Ann Author")
        try await git("config", "user.email", "ann@example.com")
        try await git("config", "commit.gpgsign", "false")
        try await git("config", "core.hooksPath", ".git/hooks")
    }

    func installHook(_ name: String, _ script: String) throws {
        let url = url(".git/hooks/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func output(_ arguments: String...) async throws -> String {
        let result = try await client.runner.run(GitCommand(arguments: arguments, workingDirectory: root))
        guard result.succeeded else { throw GitCommandFailure(exitCode: result.exitCode, message: result.errorMessage) }
        return (String(bytes: result.standardOutput, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An index older than the files it lists is one plain `git status` rewrites, so a write the
    /// client failed to suppress changes the index's identity.
    func backdateIndex() throws {
        let index = url(".git/index").path
        let written = try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date ?? Date()
        try FileManager.default.setAttributes([.modificationDate: written.addingTimeInterval(-2)], ofItemAtPath: index)
    }

    func indexIdentity() throws -> [FileAttributeKey: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url(".git/index").path)
        return [
            .systemFileNumber: attributes[.systemFileNumber] ?? 0,
            .modificationDate: attributes[.modificationDate] ?? Date.distantPast,
        ]
    }
}

@Suite("Git against a real repository", .enabled(if: GitClient.make() != nil))
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
        try repo.backdateIndex()
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

    @Test("Status runs no filter command the repository's own configuration names")
    func statusRunsNoRepositoryFilter() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        let marker = repo.url("filter-ran")
        try await repo.git("init", "-q")
        try repo.write("SELECT 1;\n", to: "a.sql")
        try repo.write("*.sql filter=tidy\n", to: ".gitattributes")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try await repo.git("config", "filter.tidy.clean", "touch '\(marker.path)'; cat")
        try repo.write("SELECT 1;\n", to: "a.sql")

        _ = try await client.status(in: repo.root)

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(
        "Status switches off a clean or process driver whatever it is called, and still sees the edit",
        arguments: ["clean", "process"], ["tidy", "a=b.c", "Ti\"dy\\", ""]
    )
    func statusRunsNoFilterOfAnyName(variable: String, driver: String) async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        let marker = repo.url("filter-ran")
        try await repo.git("init", "-q")
        try repo.write("SELECT 1;\n", to: "a.sql")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try repo.write("* filter=\(driver)\n", to: ".git/info/attributes")
        try await repo.git("config", "filter.\(driver).\(variable)", "touch '\(marker.path)'; cat")
        try await repo.git("config", "filter.\(driver).required", "true")
        try repo.write("SELECT 2;\n", to: "a.sql")

        let records = try await client.status(in: repo.root)

        #expect(records.map(\.path) == ["a.sql"])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Status refuses a repository whose filter has a name it cannot pass back to git")
    func statusRefusesUnreadableFilterName() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        let marker = repo.url("filter-ran")
        try await repo.git("init", "-q")
        try repo.write("SELECT 1;\n", to: "a.sql")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        let name = Data([0xFF, 0xFE])
        try (Data("* filter=".utf8) + name + Data("\n".utf8)).write(to: repo.url(".git/info/attributes"))
        let section = Data("[filter \"".utf8) + name + Data("\"]\n\tclean = \"touch '\(marker.path)'; cat\"\n".utf8)
        try (Data(contentsOf: repo.url(".git/config")) + section).write(to: repo.url(".git/config"))
        try repo.write("SELECT 2;\n", to: "a.sql")

        await #expect(throws: GitCommandFailure.self) { try await client.status(in: repo.root) }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Status runs no filter of a nested repository, and still reports it at another commit")
    func statusRunsNoNestedRepositoryFilter() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        let marker = repo.url("filter-ran")
        let nested = ScratchRepository(client: client, root: repo.url("vendor"))
        try FileManager.default.createDirectory(at: nested.root, withIntermediateDirectories: true)
        try await nested.git("init", "-q")
        try nested.write("SELECT 1;\n", to: "b.sql")
        try await nested.git("add", "-A")
        try await nested.git("commit", "-qm", "first")
        try await nested.git("commit", "-qm", "second", "--allow-empty")
        try await repo.git("init", "-q")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try nested.write("* filter=tidy\n", to: ".git/info/attributes")
        try await nested.git("config", "filter.tidy.clean", "touch '\(marker.path)'; cat")
        try nested.write("SELECT 2;\n", to: "b.sql")

        #expect(try await client.status(in: repo.root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        try await nested.git("update-ref", "HEAD", "HEAD~1")
        #expect(try await client.status(in: repo.root).map(\.path) == ["vendor"])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
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

    @Test("A file whose encoding macOS recorded reads its past versions in that encoding and keeps it through a restore")
    func restoreKeepsTheRecordedEncoding() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        let fixture = EncodedSQLFileFixture.shiftJISByAttribute
        let url = repo.url("japanese.sql")
        try await repo.git("init", "-q")
        try fixture.write(fixture.original, to: url)
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try fixture.write(fixture.edited, to: url)
        try await repo.git("commit", "-qam", "second")
        let provider = LinkedFileVersionHistoryProvider(fileURL: url)
        let first = try #require(try await provider.loadHistory().entries.last)

        #expect(try await provider.content(of: first.reference) == fixture.original)

        try await provider.prepareRestore(first.reference).apply()

        #expect(try Data(contentsOf: url) == fixture.bytes(of: fixture.original))
        #expect(EncodedSQLFileFixture.attributeValue(of: url) == fixture.attributeValue)
        let reloaded = try #require(FileTextLoader.load(url))
        #expect(reloaded.encoding == .shiftJIS)
        #expect(reloaded.content == fixture.original)
    }

    @Test("Discarding changes to a file whose encoding macOS recorded keeps that encoding")
    func discardKeepsTheRecordedEncoding() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        let fixture = EncodedSQLFileFixture.windowsCyrillicByAttribute
        let url = repo.url("cyrillic.sql")
        try await repo.git("init", "-q")
        try fixture.write(fixture.original, to: url)
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try fixture.write(fixture.edited, to: url)

        try await LinkedFileVersionHistoryProvider(fileURL: url).prepareDiscard().apply()

        #expect(try Data(contentsOf: url) == fixture.bytes(of: fixture.original))
        #expect(EncodedSQLFileFixture.attributeValue(of: url) == fixture.attributeValue)
        #expect(FileTextLoader.load(url)?.content == fixture.original)
    }

    private func commitDraft(in repo: ScratchRepository, folder: String, message: String) async throws -> LinkedFolderCommitDraft {
        let directory = repo.url(folder)
        let info = try #require(try await client.repositoryInfo(in: directory))
        var draft = LinkedFolderCommitDraft(records: try await client.status(in: directory), prefix: info.prefix)
        draft.message = message
        return draft
    }

    @Test("A commit from a linked folder records the checked files only and leaves other staged work staged")
    func commitOnlyTheFolder() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try await repo.configureForWrites()
        try repo.write("a\n", to: "sql/a.sql")
        try repo.write("b\n", to: "sql/b.sql")
        try repo.write("d\n", to: "sql/d.sql")
        try repo.write("app\n", to: "app/main.txt")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try repo.write("a2\n", to: "sql/a.sql")
        try FileManager.default.removeItem(at: repo.url("sql/b.sql"))
        try repo.write("c\n", to: "sql/c.sql")
        try await repo.git("rm", "-q", "sql/d.sql")
        try repo.write("app2\n", to: "app/main.txt")
        try await repo.git("add", "app/main.txt")

        let draft = try await commitDraft(in: repo, folder: "sql", message: "Update the reports")
        try await client.commit(draft.commitPaths, adding: draft.untrackedPaths, message: draft.message, in: repo.root)

        let committed = try await repo.output("show", "--name-status", "--format=%s", "HEAD")
        #expect(committed.components(separatedBy: "\n").filter { !$0.isEmpty } == [
            "Update the reports", "M\tsql/a.sql", "D\tsql/b.sql", "A\tsql/c.sql", "D\tsql/d.sql",
        ])
        let records = try await client.status(in: repo.root)
        #expect(records == [GitStatusRecord(
            path: "app/main.txt",
            originalPath: nil,
            status: GitFileStatus(staged: .modified, unstaged: .unmodified)
        )])
    }

    @Test("A staged rename inside the folder commits as a rename")
    func commitRecordsARename() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try await repo.configureForWrites()
        try repo.write("SELECT 1;\n", to: "sql/old.sql")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try await repo.git("mv", "sql/old.sql", "sql/new.sql")

        let draft = try await commitDraft(in: repo, folder: "sql", message: "Rename")
        try await client.commit(draft.commitPaths, adding: draft.untrackedPaths, message: draft.message, in: repo.root)

        #expect(try await repo.output("show", "--name-status", "-M", "--format=", "HEAD").hasPrefix("R100\tsql/old.sql\tsql/new.sql"))
        #expect(try await client.status(in: repo.root).isEmpty)
    }

    @Test("A new file at a rename's old path stays out of the commit until its own box is checked")
    func renameSourceRecreatedStaysOut() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try await repo.configureForWrites()
        try repo.write("SELECT 1;\n", to: "sql/old.sql")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try await repo.git("mv", "sql/old.sql", "sql/new.sql")
        try repo.write("SELECT 2;\n", to: "sql/old.sql")

        var draft = try await commitDraft(in: repo, folder: "sql", message: "Rename")
        let recreated = try #require(draft.entries.first { $0.path == "sql/old.sql" })
        draft.setChecked(recreated, false)
        try await client.commit(draft.commitPaths, adding: draft.untrackedPaths, message: draft.message, in: repo.root)

        #expect(try await repo.output("show", "--name-status", "--format=", "HEAD") == "A\tsql/new.sql")
        #expect(try await repo.output("show", "HEAD:sql/old.sql") == "SELECT 1;")
    }

    @Test("A pre-commit hook runs, and its refusal comes back with what it printed")
    func commitRunsHooks() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try await repo.configureForWrites()
        try repo.write("SELECT 1;\n", to: "q.sql")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try repo.write("SELECT 2;\n", to: "q.sql")
        try repo.installHook("pre-commit", "echo 'lint failed' >&2\nexit 1")
        let head = try await client.headCommit(in: repo.root)

        let failure = await #expect(throws: GitCommandFailure.self) {
            try await client.commit(["q.sql"], message: "Second", in: repo.root)
        }
        #expect(failure?.message.contains("lint failed") == true)
        #expect(try await client.headCommit(in: repo.root) == head)
    }

    @Test("A hook that leaves a background job holding git's output does not hold up the commit")
    func backgroundHookJobDoesNotStall() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try await repo.configureForWrites()
        try repo.write("SELECT 1;\n", to: "q.sql")
        try repo.installHook("post-commit", "sleep 25 &")
        let clock = ContinuousClock()
        let started = clock.now

        try await client.commit(["q.sql"], adding: ["q.sql"], message: "First", in: repo.root)

        #expect(clock.now - started < .seconds(10))
        #expect(try await repo.output("log", "-1", "--format=%s") == "First")
    }

    @Test("Cancelling a commit ends the git process and the hook it is waiting on")
    func cancellingACommitStopsGit() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        try await repo.configureForWrites()
        try repo.write("SELECT 1;\n", to: "q.sql")
        try repo.installHook("pre-commit", "touch hook-started\nsleep 25")
        let client = client
        let root = repo.root
        let commit = Task { try await client.commit(["q.sql"], adding: ["q.sql"], message: "First", in: root) }
        try await waitUntil { FileManager.default.fileExists(atPath: repo.url("hook-started").path) }
        let clock = ContinuousClock()
        let cancelled = clock.now

        commit.cancel()

        await #expect(throws: CancellationError.self) { try await commit.value }
        #expect(clock.now - cancelled < .seconds(10))
        #expect(try await client.headCommit(in: repo.root) == nil)
    }

    @Test("Pull fast-forwards from the upstream, and a commit pushed from the folder reaches the remote branch")
    func pullThenCommitAndPush() async throws {
        let workspace = try ScratchRepository(client: client)
        defer { workspace.remove() }
        try await workspace.git("init", "-q", "--bare", "remote.git")
        try await workspace.git("clone", "-q", "remote.git", "teammate")
        let teammate = ScratchRepository(client: client, root: workspace.url("teammate"))
        try await teammate.configureForWrites()
        try teammate.write("SELECT 1;\n", to: "sql/report.sql")
        try await teammate.git("add", "-A")
        try await teammate.git("commit", "-qm", "Add the report")
        try await teammate.git("push", "-q", "origin", "HEAD:main")
        try await workspace.git("clone", "-q", "remote.git", "mine")
        let mine = ScratchRepository(client: client, root: workspace.url("mine"))
        try await mine.configureForWrites()
        try teammate.write("SELECT 2;\n", to: "sql/report.sql")
        try await teammate.git("commit", "-qam", "Teammate's change")
        try await teammate.git("push", "-q", "origin", "HEAD:main")

        try await client.pull(in: mine.root)
        #expect(try mine.read("sql/report.sql") == "SELECT 2;\n")

        try mine.write("SELECT 3;\n", to: "sql/report.sql")
        let draft = try await commitDraft(in: mine, folder: "sql", message: "My change")
        try await client.commit(draft.commitPaths, adding: draft.untrackedPaths, message: draft.message, in: mine.root)
        try await client.push(in: mine.root)

        let remoteLog = try await workspace.output("--git-dir=\(workspace.url("remote.git").path)", "log", "-1", "--format=%s", "main")
        #expect(remoteLog == "My change")
    }

    @Test("Pull fast-forwards a partial clone, fetching the files the new commit needs as Terminal git does")
    func pullIntoPartialClone() async throws {
        let workspace = try ScratchRepository(client: client)
        defer { workspace.remove() }
        try await workspace.git("init", "-q", "--bare", "remote.git")
        try await workspace.git("--git-dir=remote.git", "config", "uploadpack.allowFilter", "true")
        try await workspace.git("clone", "-q", "remote.git", "teammate")
        let teammate = ScratchRepository(client: client, root: workspace.url("teammate"))
        try await teammate.configureForWrites()
        try teammate.write("SELECT 1;\n", to: "report.sql")
        try await teammate.git("add", "-A")
        try await teammate.git("commit", "-qm", "First")
        try await teammate.git("push", "-q", "origin", "HEAD:main")
        try await workspace.git("clone", "-q", "--filter=blob:none", workspace.url("remote.git").absoluteString, "mine")
        let mine = ScratchRepository(client: client, root: workspace.url("mine"))
        try teammate.write("SELECT 2;\n", to: "report.sql")
        try await teammate.git("commit", "-qam", "Second")
        try await teammate.git("push", "-q", "origin", "HEAD:main")

        try await client.pull(in: mine.root)

        #expect(try mine.read("report.sql") == "SELECT 2;\n")
    }

    @Test("A pull that cannot fast-forward stops, says so, and leaves the branch where it was")
    func divergedPullStops() async throws {
        let workspace = try ScratchRepository(client: client)
        defer { workspace.remove() }
        try await workspace.git("init", "-q", "--bare", "remote.git")
        try await workspace.git("clone", "-q", "remote.git", "teammate")
        let teammate = ScratchRepository(client: client, root: workspace.url("teammate"))
        try await teammate.configureForWrites()
        try teammate.write("SELECT 1;\n", to: "a.sql")
        try await teammate.git("add", "-A")
        try await teammate.git("commit", "-qm", "First")
        try await teammate.git("push", "-q", "origin", "HEAD:main")
        try await workspace.git("clone", "-q", "remote.git", "mine")
        let mine = ScratchRepository(client: client, root: workspace.url("mine"))
        try await mine.configureForWrites()
        try await mine.git("config", "pull.rebase", "true")
        try teammate.write("SELECT 2;\n", to: "a.sql")
        try await teammate.git("commit", "-qam", "Theirs")
        try await teammate.git("push", "-q", "origin", "HEAD:main")
        try mine.write("SELECT 1;\n", to: "b.sql")
        try await mine.git("add", "-A")
        try await mine.git("commit", "-qm", "Mine")
        let head = try await client.headCommit(in: mine.root)

        await #expect(throws: GitPullDiverged.self) { try await client.pull(in: mine.root) }
        #expect(try await client.headCommit(in: mine.root) == head)
        #expect(!FileManager.default.fileExists(atPath: mine.url(".git/rebase-merge").path))
        #expect(try mine.read("a.sql") == "SELECT 1;\n")
    }

    private func diff(of path: String, in repo: ScratchRepository) async throws -> LinkedFolderCommitDiff {
        let draft = LinkedFolderCommitDraft(records: try await client.status(in: repo.root), prefix: "")
        let entry = try #require(draft.entries.first { $0.path == path })
        return await LinkedFolderCommitDiffLoader.load(entry, topLevel: repo.root, hasHead: true, client: client)
    }

    @Test("The commit sheet compares an intent-to-add file, a UTF-16 file without a byte order mark and a symbolic link as text")
    func commitDiffReadsNewAndWideFiles() async throws {
        let repo = try ScratchRepository(client: client)
        defer { repo.remove() }
        try await repo.git("init", "-q")
        let wide = try #require("SELECT id, name FROM customers WHERE active = 1;\n".data(using: .utf16LittleEndian))
        try wide.write(to: repo.url("wide.sql"))
        try await repo.git("add", "-A")
        try await repo.git("commit", "-qm", "first")
        try #require("SELECT id, name FROM customers WHERE active = 0;\n".data(using: .utf16LittleEndian))
            .write(to: repo.url("wide.sql"))
        try repo.write("SELECT 3;\n", to: "planned.sql")
        try await repo.git("add", "--intent-to-add", "planned.sql")
        try FileManager.default.createSymbolicLink(atPath: repo.url("latest.sql").path, withDestinationPath: "wide.sql")

        guard case .comparison(.differs(let widePairs)) = try await diff(of: "wide.sql", in: repo) else {
            Issue.record("A UTF-16 file must compare as text")
            return
        }
        #expect(widePairs.contains { $0.after == "SELECT id, name FROM customers WHERE active = 0;" })
        guard case .comparison(.differs(let newPairs)) = try await diff(of: "planned.sql", in: repo) else {
            Issue.record("An intent-to-add file must compare against nothing")
            return
        }
        #expect(newPairs.contains { $0.kind == .added && $0.after == "SELECT 3;" })
        guard case .comparison(.differs(let linkPairs)) = try await diff(of: "latest.sql", in: repo) else {
            Issue.record("A symbolic link must compare as the path it points to")
            return
        }
        #expect(linkPairs.compactMap(\.after) == ["wide.sql"])
    }
}

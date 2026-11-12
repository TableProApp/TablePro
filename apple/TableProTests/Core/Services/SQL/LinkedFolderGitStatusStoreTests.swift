import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite(.enabled(if: GitClient.make() != nil))
struct LinkedFolderGitStatusStoreTests {
    @Test("Switching back asks Git only about folders outside a repository, once each")
    func activationAsksOnlyFoldersOutsideARepository() async throws {
        let real = try #require(GitClient.make())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkedFolderGitStatusStoreTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initialized = try await real.runner.run(
            GitCommand(arguments: ["init", "-q"], workingDirectory: repository, access: .write)
        )
        #expect(initialized.succeeded)

        let log = root.appendingPathComponent("invocations.log")
        let wrapper = root.appendingPathComponent("git")
        let script = "#!/bin/sh\npwd -P >> '\(log.path)'\nexec '\(real.runner.executableURL.path)' \"$@\"\n"
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let client = GitClient(runner: GitProcessRunner(executableURL: wrapper))
        let folders = [LinkedSQLFolder(path: repository.path), LinkedSQLFolder(path: plain.path)]
        let store = LinkedFolderGitStatusStore(clientFactory: { client }, foldersProvider: { folders })

        await store.refresh()
        #expect(store.snapshots.count == 1)
        try Data().write(to: log)

        await store.lookForNewRepositories()?.value

        // `pwd -P` prints the /private/var path; resolving strips that prefix again.
        let asked = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path }
        #expect(asked == [plain.path])
    }
}

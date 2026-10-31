//
//  GitOutputParserTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro
@testable import TableProUtilities

struct GitOutputParserTests {
    private func bytes(_ string: String) -> Data {
        Data(string.utf8)
    }

    @Test("Porcelain v2 records keep spaces and non-ASCII in paths, and a rename carries its original path")
    func statusRecords() {
        let output = bytes(
            "1 .M N... 100644 100644 100644 aaaa bbbb sql queries/a b.sql\0"
                + "1 MM N... 100644 100644 100644 aaaa bbbb sql queries/staged.sql\0"
                + "1 A. N... 000000 100644 100644 0000 bbbb sql queries/added.sql\0"
                + "2 R. N... 100644 100644 100644 aaaa aaaa R100 sql queries/new name.sql\0sql queries/old name.sql\0"
                + "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc sql queries/conflict.sql\0"
                + "? sql queries/日本.sql\0"
        )

        let records = GitStatusParser.parse(output)

        #expect(records.map(\.path) == [
            "sql queries/a b.sql",
            "sql queries/staged.sql",
            "sql queries/added.sql",
            "sql queries/new name.sql",
            "sql queries/conflict.sql",
            "sql queries/日本.sql",
        ])
        #expect(records[0].status == GitFileStatus(staged: .unmodified, unstaged: .modified))
        #expect(records[1].status == GitFileStatus(staged: .modified, unstaged: .modified))
        #expect(records[2].status == GitFileStatus(staged: .added, unstaged: .unmodified))
        #expect(records[3].originalPath == "sql queries/old name.sql")
        #expect(records[3].status.staged == .renamed)
        #expect(records[4].status.isConflicted)
        #expect(records[5].status.isUntracked)
    }

    @Test("Every unmerged record is a conflict, including add/add where XY has no U")
    func addAddConflict() throws {
        let output = bytes("u AA N... 000000 100644 100644 100644 0000 6178 7898 q/c.sql\0")
        let record = try #require(GitStatusParser.parse(output).first)
        #expect(record.status.isConflicted)
        #expect(record.status.badge == .conflicted)
        #expect(!record.status.canDiscardChanges)
    }

    @Test("An empty status is no records")
    func emptyStatus() {
        #expect(GitStatusParser.parse(Data()).isEmpty)
    }

    @Test("A followed log reports each commit with the path the file had at that commit")
    func logFollowsRenames() throws {
        let output = bytes(
            "\u{1E}4e3138764045879d706b709d7f4dd42897109548\u{1F}Ann Author\u{1F}2026-09-23T10:09:04+07:00"
                + "\u{1F}subject with \u{1F}? no; tab\there\0\nM\0sub dir/new name.sql\0"
                + "\u{1E}1189ca3714ed5cee0a4b5885a64adb10d8bcb830\u{1F}Ann Author\u{1F}2026-09-23T10:09:04+07:00"
                + "\u{1F}rename it\0\nR100\0sub dir/old name.sql\0sub dir/new name.sql\0"
                + "\u{1E}9362855bae5a38735f19ddcfc763bba0cf5a2df2\u{1F}Ann Author\u{1F}2026-09-23T10:09:03+07:00\u{1F}second\0\nM\0sub dir/old name.sql\0"
                + "\u{1E}d5fc769941d0c335980f7be7b6df3a2bcefdd9fd\u{1F}Ann Author\u{1F}2026-09-23T10:09:03+07:00\u{1F}first: add\0\nA\0sub dir/old name.sql\0"
        )

        let commits = GitLogParser.parse(output)

        #expect(commits.map { String($0.hash.prefix(4)) } == ["4e31", "1189", "9362", "d5fc"])
        #expect(commits.map(\.path) == [
            "sub dir/new name.sql",
            "sub dir/new name.sql",
            "sub dir/old name.sql",
            "sub dir/old name.sql",
        ])
        #expect(commits[0].subject == "subject with \u{1F}? no; tab\there")
        #expect(commits[3].subject == "first: add")
        #expect(commits[0].author == "Ann Author")
        let date = try #require(commits[0].date)
        #expect(date == Date(timeIntervalSince1970: 1_790_132_944))
    }

    @Test("A commit with no file entry keeps its header and leaves the path unknown")
    func logCommitWithoutPath() {
        let output = bytes("\u{1E}abcd\(String(repeating: "0", count: 36))\u{1F}Ann\u{1F}2026-09-23T10:09:04+07:00\u{1F}merge\0")
        let commits = GitLogParser.parse(output)
        #expect(commits.count == 1)
        #expect(commits[0].path == nil)
    }

    @Test("A commit that deleted the file has no version to show and is skipped")
    func logSkipsDeletions() {
        let deleted = "b".padding(toLength: 40, withPad: "b", startingAt: 0)
        let added = "c".padding(toLength: 40, withPad: "c", startingAt: 0)
        let output = bytes(
            "\u{1E}\(deleted)\u{1F}Ann\u{1F}2026-09-23T10:09:04+07:00\u{1F}drop it\0\nD\0q.sql\0"
                + "\u{1E}\(added)\u{1F}Ann\u{1F}2026-09-22T10:09:04+07:00\u{1F}add it\0\nA\0q.sql\0"
        )
        #expect(GitLogParser.parse(output).map(\.hash) == [added])
    }

    @Test("A header whose hash is not a commit id is dropped, so it can never reach a cat-file argument")
    func logRejectsNonHashHeaders() {
        let output = bytes("\u{1E}--batch-check\u{1F}Ann\u{1F}2026-09-23T10:09:04+07:00\u{1F}x\0\nM\0q.sql\0")
        #expect(GitLogParser.parse(output).isEmpty)
        #expect(GitLogParser.isCommitHash(Substring(String(repeating: "a", count: 64))))
        #expect(!GitLogParser.isCommitHash("HEAD"))
    }

    @Test("rev-parse output maps to the top level, the git directory and the prefix, which is empty at the root")
    func repositoryInfo() throws {
        let nested = try #require(GitRepositoryInfoParser.parse(bytes("/tmp/repo\n/tmp/repo/.git\nsql queries/\n")))
        #expect(nested.topLevel.path == "/tmp/repo")
        #expect(nested.gitDirectory.path == "/tmp/repo/.git")
        #expect(nested.prefix == "sql queries/")

        let root = try #require(GitRepositoryInfoParser.parse(bytes("/tmp/repo\n/tmp/repo/.git\n\n")))
        #expect(root.prefix.isEmpty)

        #expect(GitRepositoryInfoParser.parse(Data()) == nil)
    }

    @Test("A file with no status is clean only when the index tracks it")
    func trackedVersusIgnored() throws {
        let snapshot = LinkedFolderGitSnapshot(
            repository: try #require(GitRepositoryInfoParser.parse(bytes("/r\n/r/.git\n\n"))),
            head: nil,
            statuses: ["new.sql": .untracked],
            trackedPaths: ["clean.sql"]
        )
        #expect(snapshot.state(forRelativePath: "clean.sql") == .clean)
        #expect(snapshot.state(forRelativePath: "new.sql") == .changed(.untracked))
        #expect(snapshot.state(forRelativePath: "ignored.sql") == nil)
        #expect(LinkedFolderGitStatusStore.folderRelativePaths(["q/a.sql", "other/b.sql"], prefix: "q/") == ["a.sql"])
    }

    @Test("Statuses are keyed by the path inside the linked folder, and files outside it are dropped")
    func folderRelativeStatuses() {
        let records = [
            GitStatusRecord(path: "sql queries/a.sql", originalPath: nil, status: .untracked),
            GitStatusRecord(path: "sql queries/nested/b.sql", originalPath: nil, status: GitFileStatus(staged: .unmodified, unstaged: .modified)),
            GitStatusRecord(path: "other/c.sql", originalPath: nil, status: .untracked),
        ]

        let statuses = LinkedFolderGitStatusStore.folderRelativeStatuses(records, prefix: "sql queries/")

        #expect(Set(statuses.keys) == ["a.sql", "nested/b.sql"])
        #expect(LinkedFolderGitStatusStore.folderRelativeStatuses(records, prefix: "").count == 3)
    }
}

struct GitFileStatusTests {
    @Test("Badge letters follow the change, with conflict and untracked first")
    func badges() {
        #expect(GitFileStatus(staged: .unmodified, unstaged: .modified).badge == .modified)
        #expect(GitFileStatus(staged: .modified, unstaged: .unmodified).badge == .modified)
        #expect(GitFileStatus(staged: .added, unstaged: .modified).badge == .added)
        #expect(GitFileStatus(staged: .renamed, unstaged: .unmodified).badge == .renamed)
        #expect(GitFileStatus(staged: .unmerged, unstaged: .unmerged).badge == .conflicted)
        #expect(GitFileStatus.untracked.badge == .untracked)
        #expect(GitFileStatus.untracked.badge.letter == "U")
        #expect(GitFileStatus(code: ".A").badge == .added)
    }

    @Test("Discard is offered only when the working copy differs from the index")
    func discardGating() {
        #expect(GitFileStatus(staged: .unmodified, unstaged: .modified).canDiscardChanges)
        #expect(GitFileStatus(staged: .modified, unstaged: .modified).canDiscardChanges)
        #expect(GitFileStatus(staged: .added, unstaged: .modified).canDiscardChanges)
        #expect(!GitFileStatus(staged: .modified, unstaged: .unmodified).canDiscardChanges)
        #expect(!GitFileStatus(staged: .added, unstaged: .unmodified).canDiscardChanges)
        #expect(!GitFileStatus.untracked.canDiscardChanges)
        #expect(!GitFileStatus(staged: .unmerged, unstaged: .unmerged).canDiscardChanges)
    }

    @Test("History is offered only for a file that exists in a commit under this name")
    func committedHistory() {
        #expect(GitFileStatus(staged: .unmodified, unstaged: .modified).hasCommittedHistory)
        #expect(GitFileStatus(staged: .modified, unstaged: .unmodified).hasCommittedHistory)
        #expect(!GitFileStatus(staged: .added, unstaged: .unmodified).hasCommittedHistory)
        #expect(!GitFileStatus(staged: .renamed, unstaged: .unmodified).hasCommittedHistory)
        #expect(!GitFileStatus.untracked.hasCommittedHistory)
        #expect(!GitFileStatus(code: ".A").hasCommittedHistory)
        #expect(LinkedFileGitState.clean.hasCommittedHistory)
        #expect(!LinkedFileGitState.clean.canDiscardChanges)
    }

    @Test("The spoken status says whether the change is staged")
    func accessibilityDescription() {
        #expect(GitFileStatus(staged: .modified, unstaged: .unmodified).accessibilityDescription
            == String(format: String(localized: "%@, staged"), GitFileStatus.Badge.modified.label))
        #expect(GitFileStatus(staged: .modified, unstaged: .modified).accessibilityDescription
            == String(format: String(localized: "%@, partly staged"), GitFileStatus.Badge.modified.label))
        #expect(GitFileStatus(staged: .unmodified, unstaged: .modified).accessibilityDescription
            == GitFileStatus.Badge.modified.label)
    }
}

struct GitCommandHardeningTests {
    @Test("The locator never offers the installer shim, and reads the developer directory without running anything")
    func locatorSkipsShim() {
        let locator = GitExecutableLocator(
            isExecutable: { _ in true },
            developerDirectory: { "/Applications/Xcode.app/Contents/Developer" }
        )
        let candidates = locator.candidates()
        #expect(!candidates.contains("/usr/bin/git"))
        #expect(candidates.contains("/Applications/Xcode.app/Contents/Developer/usr/bin/git"))
        #expect(locator.locate()?.path == "/opt/homebrew/bin/git")
    }

    @Test("A developer directory at the volume root cannot smuggle the shim back in")
    func locatorRejectsShimViaDeveloperDirectory() {
        let locator = GitExecutableLocator(isExecutable: { _ in true }, developerDirectory: { "/" })
        #expect(!locator.candidates().contains("/usr/bin/git"))
    }

    @Test("No git installed means no git, not the shim")
    func locatorWithoutGit() {
        let locator = GitExecutableLocator(isExecutable: { $0 == "/usr/bin/git" }, developerDirectory: { nil })
        #expect(locator.locate() == nil)
    }

    @Test("Every command carries the flags that stop a repository from running its own programs or taking locks")
    func everyCommandIsHardened() {
        let file = URL(fileURLWithPath: "/tmp/repo/a.sql")
        let directory = file.deletingLastPathComponent()
        let commands: [GitCommand] = [
            .repositoryInfo(in: directory),
            .verifyHead(in: directory),
            .configuration(in: directory),
            .status(in: directory),
            .fileHistory(of: file, limit: 10),
            .blob(revision: "HEAD", path: "a.sql", in: directory),
            .trackedFiles(in: directory),
            .currentBranch(in: directory),
            .upstreamDivergence(in: directory),
            .changedPaths(from: "a", to: "b", in: directory),
        ]
        for command in commands {
            let arguments = command.processArguments
            #expect(arguments.starts(with: GitCommand.hardeningArguments))
            #expect(arguments.contains("core.fsmonitor=false"))
            #expect(arguments.contains("core.hooksPath=/dev/null"))
            #expect(arguments.contains("--no-optional-locks"))
            #expect(arguments.contains("--literal-pathspecs"))
            #expect(!arguments.contains("--filters"))
            #expect(!arguments.contains("checkout-index"))
        }
        #expect(GitCommand.blob(revision: "HEAD", path: "a.sql", in: directory).arguments.contains("--end-of-options"))
    }

    @Test("Every filter driver the configuration lists counts, whatever its scope or name")
    func filterDrivers() {
        let keys = [
            "core.bare", "filter.lfs.process", "filter.lfs.required", "filter.tidy.clean", "filter.smudge",
            "filter.a=b.c.process", "filter.a.b.clean", "filter..clean", "filter.Ti\"dy\\.clean", "filter.tidy.required",
        ]
        let listing = Data((keys.joined(separator: "\0") + "\0").utf8)
        #expect(GitFilterDriverParser.parse(listing) == ["lfs", "tidy", "a=b.c", "a.b", "", "Ti\"dy\\"])
        #expect(GitFilterDriverParser.parse(Data()) == [])
        #expect(GitFilterDriverParser.parse(Data("core.bare\0filter.\u{301}x.clean\0".utf8)) == nil)
        #expect(GitFilterDriverParser.parse(Data("filter.".utf8) + Data([0xFF]) + Data(".clean\0".utf8)) == nil)
    }

    @Test("Status switches off each listed driver for its own process and stays out of nested repositories")
    func statusDisablesFilters() throws {
        let directory = URL(fileURLWithPath: "/tmp/repo")
        let plain = GitCommand.status(in: directory)
        #expect(plain.arguments.contains("--ignore-submodules=dirty"))
        #expect(!plain.processArguments.contains { $0.hasPrefix("--config-env") })
        #expect(plain.environment(base: [:])[GitCommand.emptyValueVariable] == nil)

        let command = GitCommand.status(in: directory, disablingFilters: ["a=b", ""])
        let overrides = command.processArguments.filter { $0.hasPrefix("--config-env") }
        #expect(overrides == [
            "--config-env=filter.a=b.clean=TABLEPRO_GIT_EMPTY_VALUE",
            "--config-env=filter.a=b.process=TABLEPRO_GIT_EMPTY_VALUE",
            "--config-env=filter.a=b.required=TABLEPRO_GIT_EMPTY_VALUE",
            "--config-env=filter..clean=TABLEPRO_GIT_EMPTY_VALUE",
            "--config-env=filter..process=TABLEPRO_GIT_EMPTY_VALUE",
            "--config-env=filter..required=TABLEPRO_GIT_EMPTY_VALUE",
        ])
        let lastOverride = try #require(command.processArguments.lastIndex { $0.hasPrefix("--config-env") })
        let subcommand = try #require(command.processArguments.firstIndex(of: "status"))
        #expect(subcommand > lastOverride)
        #expect(command.environment(base: [GitCommand.emptyValueVariable: "x"])[GitCommand.emptyValueVariable] == "")
    }

    @Test("A read reaches no remote, and a write fetches what it needs as Terminal git does")
    func readsReachNoRemote() {
        let directory = URL(fileURLWithPath: "/tmp/repo")
        let base = ["PATH": "/usr/bin", "GIT_ALLOW_PROTOCOL": "file:ssh", "GIT_NO_LAZY_FETCH": "0"]
        let reads: [GitCommand] = [
            .status(in: directory),
            .configuration(in: directory),
            .blob(revision: "HEAD", path: "a.sql", in: directory),
            .fileHistory(of: directory.appendingPathComponent("a.sql"), limit: 10),
            .changedPaths(from: "a", to: "b", in: directory),
        ]
        for command in reads {
            let environment = command.environment(base: base)
            #expect(environment["GIT_ALLOW_PROTOCOL"] == "")
            #expect(environment["GIT_NO_LAZY_FETCH"] == "1")
        }
        for command in [GitCommand.pull(in: directory), .push(in: directory), .commit(["a.sql"], message: "Fix", in: directory)] {
            let environment = command.environment(base: ["PATH": "/usr/bin"])
            #expect(environment["GIT_ALLOW_PROTOCOL"] == nil)
            #expect(environment["GIT_NO_LAZY_FETCH"] == nil)
        }
    }

    @Test("A write command runs the repository's hooks as Terminal git does and keeps the rest of the hardening")
    func writeCommandsRunHooks() {
        let directory = URL(fileURLWithPath: "/tmp/repo")
        let commands: [GitCommand] = [
            .stage(["a.sql"], in: directory),
            .commit(["a.sql"], message: "Fix", in: directory),
            .pull(in: directory),
            .push(in: directory),
        ]
        for command in commands {
            let arguments = command.processArguments
            #expect(arguments.starts(with: GitCommand.hardeningArguments))
            #expect(!arguments.contains("core.hooksPath=/dev/null"))
            #expect(!arguments.contains { $0.hasPrefix("--force") || $0 == "-f" || $0.hasPrefix("--rebase") })
            #expect(command.access == .write)
            #expect(command.timeout == GitCommand.writeTimeout)
        }
    }

    @Test("A pull only fast-forwards, and stage and commit name only the paths they were given")
    func writeArguments() {
        let directory = URL(fileURLWithPath: "/tmp/repo")
        #expect(GitCommand.pull(in: directory).arguments == ["pull", "--no-rebase", "--ff-only"])
        #expect(GitCommand.push(in: directory).arguments == ["push"])
        #expect(GitCommand.stage(["-n.sql"], in: directory).arguments == ["add", "--", "-n.sql"])
        #expect(GitCommand.commit(["q/a.sql"], message: "--amend", in: directory).arguments == [
            "commit", "--only", "--message=--amend", "--", "q/a.sql",
        ])
    }

    @Test("A write command finds tools installed with Homebrew, and a read keeps the inherited PATH")
    func writeEnvironment() {
        let directory = URL(fileURLWithPath: "/tmp/repo")
        let base = ["PATH": "/usr/bin:/bin", "GIT_DIR": "/elsewhere/.git"]
        let write = GitCommand.push(in: directory).environment(base: base)
        #expect(write["PATH"]?.split(separator: ":").contains("/opt/homebrew/bin") == true)
        #expect(write["GIT_DIR"] == nil)
        #expect(write["GIT_TERMINAL_PROMPT"] == "0")
        #expect(GitCommand.status(in: directory).environment(base: base)["PATH"] == "/usr/bin:/bin")
    }

    @Test("A failed write reports what git printed on either stream")
    func combinedOutput() {
        let result = GitProcessResult(
            exitCode: 1,
            standardOutput: Data("nothing to commit, working tree clean\n".utf8),
            standardError: Data("hint: something\n".utf8)
        )
        #expect(result.combinedOutput == "nothing to commit, working tree clean\nhint: something")
        #expect(result.errorMessage == "hint: something")
    }

    @Test("A file history never asks git to verify signatures or colour its output")
    func historyArguments() {
        let command = GitCommand.fileHistory(of: URL(fileURLWithPath: "/tmp/repo/sub dir/a b.sql"), limit: 201)
        #expect(command.arguments.contains("--follow"))
        #expect(command.arguments.contains("--no-show-signature"))
        #expect(command.arguments.contains("--no-color"))
        #expect(command.arguments.contains("--max-count=201"))
        #expect(command.arguments.last == "a b.sql")
        #expect(command.workingDirectory.path == "/tmp/repo/sub dir")
    }

    @Test("Inherited repository variables are dropped and the lock and prompt overrides win")
    func environment() {
        let environment = GitCommand.environment(base: [
            "GIT_DIR": "/elsewhere/.git",
            "GIT_WORK_TREE": "/elsewhere",
            "GIT_CONFIG": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "1",
            "PATH": "/usr/bin",
        ])
        #expect(environment["GIT_DIR"] == nil)
        #expect(environment["GIT_WORK_TREE"] == nil)
        #expect(environment["GIT_CONFIG"] == nil)
        #expect(environment["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(environment["PATH"] == "/usr/bin")
    }

    @Test("Folder watcher events inside .git do not count as SQL file changes")
    func repositoryMetadataEvents() {
        #expect(SQLFolderWatcher.touchesOnlyRepositoryMetadata(["/repo/.git/index", "/repo/.git/refs/heads/main"]))
        #expect(!SQLFolderWatcher.touchesOnlyRepositoryMetadata(["/repo/.git/index", "/repo/queries/a.sql"]))
        #expect(!SQLFolderWatcher.touchesOnlyRepositoryMetadata(["/repo/.gitignore"]))
        #expect(!SQLFolderWatcher.touchesOnlyRepositoryMetadata([]))
    }
}

struct FileTextLoaderDecodeTests {
    @Test("Byte order marks pick the encoding, UTF-32 before the UTF-16 prefix it shares")
    func byteOrderMarks() throws {
        let text = "SELECT 'é';"
        let utf32 = try #require(text.data(using: .utf32LittleEndian))
        let utf16 = try #require(text.data(using: .utf16LittleEndian))
        #expect(FileTextLoader.decode(Data([0xFF, 0xFE, 0x00, 0x00]) + utf32) == text)
        #expect(FileTextLoader.decode(Data([0xFF, 0xFE]) + utf16) == text)
        #expect(FileTextLoader.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)) == text)
        #expect(FileTextLoader.decode(Data(text.utf8)) == text)
        #expect(FileTextLoader.decode(Data([0x53, 0xE9])) == "Sé")
    }

    @Test("A big-endian UTF-32 blob and an empty blob decode")
    func bigEndianAndEmpty() throws {
        let text = "SELECT 'é';"
        let utf32 = try #require(text.data(using: .utf32BigEndian))
        #expect(FileTextLoader.decode(Data([0x00, 0x00, 0xFE, 0xFF]) + utf32) == text)
        #expect(FileTextLoader.decode(Data()) == "")
    }

    @Test("A blob with no mark reads in the declared encoding, and a mark still outranks it")
    func declaredEncoding() throws {
        let text = "SELECT '\u{65E5}\u{672C}';"
        let shiftJIS = try #require(text.data(using: .shiftJIS))
        let utf16 = try #require(text.data(using: .utf16BigEndian))
        #expect(FileTextLoader.decode(shiftJIS, declaredEncoding: .shiftJIS) == text)
        #expect(FileTextLoader.decode(shiftJIS) != text)
        #expect(FileTextLoader.decode(Data([0xFE, 0xFF]) + utf16, declaredEncoding: .shiftJIS) == text)
    }

    @Test("An older version saved as UTF-8 reads as UTF-8 under a working copy recorded as Latin-1")
    func utf8BlobOutranksASingleByteDeclaration() {
        let text = "SELECT 'café';"
        #expect(FileTextLoader.decode(Data(text.utf8), declaredEncoding: .isoLatin1) == text)
    }
}

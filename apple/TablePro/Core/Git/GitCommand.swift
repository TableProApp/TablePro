//
//  GitCommand.swift
//  TablePro
//

import Foundation

internal struct GitCommand: Equatable, Sendable {
    internal enum Access: Equatable, Sendable {
        case read
        // Runs the repository's hooks and the user's tools, as `git` in Terminal does.
        case write
    }

    let arguments: [String]
    let workingDirectory: URL
    var access: Access = .read
    var timeout: TimeInterval?
    var disabledFilters: [String] = []

    static let writeTimeout: TimeInterval = 300

    static let hardeningArguments: [String] = [
        "--no-optional-locks",
        "--no-pager",
        "--literal-pathspecs",
        "-c", "core.fsmonitor=false",
        "-c", "color.ui=never",
        "-c", "log.showSignature=false",
        "-c", "safe.bareRepository=explicit",
    ]

    static let readOnlyArguments: [String] = ["-c", "core.hooksPath=/dev/null"]

    static let environmentOverrides: [String: String] = [
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_PAGER": "cat",
    ]

    // Git before 2.44 ignores GIT_NO_LAZY_FETCH; an empty allow list stops the transport a lazy fetch would use.
    static let readOnlyEnvironment: [String: String] = [
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_ALLOW_PROTOCOL": "",
    ]

    static let emptyValueVariable = "TABLEPRO_GIT_EMPTY_VALUE"
    static let disabledFilterVariables = ["clean", "process", "required"]

    static let inheritedRepositoryVariables: Set<String> = [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_NAMESPACE",
        "GIT_CEILING_DIRECTORIES",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
        // Points `git config` alone at another file, so the filter listing would miss the repository's drivers.
        "GIT_CONFIG",
        "GIT_EXTERNAL_DIFF",
    ]

    static let historyFormat = "%x1e%H%x1f%an%x1f%aI%x1f%s"

    var processArguments: [String] {
        Self.hardeningArguments + (access == .read ? Self.readOnlyArguments : []) + filterArguments + arguments
    }

    // `--config-env` splits at the last `=`, unlike `-c`, and git before 2.31 stops on it rather than run the filter.
    private var filterArguments: [String] {
        disabledFilters.flatMap { driver in
            Self.disabledFilterVariables.map { "--config-env=filter.\(driver).\($0)=\(Self.emptyValueVariable)" }
        }
    }

    func environment(base: [String: String]) -> [String: String] {
        var environment = Self.environment(base: access == .write ? CLIToolEnvironment.augmented(base) : base)
        if access == .read {
            environment.merge(Self.readOnlyEnvironment) { _, override in override }
        }
        if !disabledFilters.isEmpty {
            environment[Self.emptyValueVariable] = ""
        }
        return environment
    }

    static func environment(base: [String: String]) -> [String: String] {
        var environment = base.filter { !inheritedRepositoryVariables.contains($0.key) }
        environment.merge(environmentOverrides) { _, override in override }
        return environment
    }

    static func repositoryInfo(in directory: URL) -> GitCommand {
        GitCommand(
            arguments: ["rev-parse", "--show-toplevel", "--absolute-git-dir", "--show-prefix"],
            workingDirectory: directory
        )
    }

    static func verifyHead(in directory: URL) -> GitCommand {
        GitCommand(arguments: ["rev-parse", "--verify", "--quiet", "HEAD"], workingDirectory: directory)
    }

    static func configuration(in directory: URL) -> GitCommand {
        GitCommand(arguments: ["config", "--list", "--name-only", "-z"], workingDirectory: directory)
    }

    // Status pipes a stale file through its filter driver and runs its own status inside a nested repository.
    static func status(in directory: URL, pathspec: String = ".", disablingFilters filters: [String] = []) -> GitCommand {
        GitCommand(
            arguments: [
                "status", "--porcelain=v2", "-z", "--untracked-files=all", "--find-renames",
                "--ignore-submodules=dirty", "--", pathspec,
            ],
            workingDirectory: directory,
            disabledFilters: filters
        )
    }

    static func trackedFiles(in directory: URL) -> GitCommand {
        GitCommand(arguments: ["ls-files", "-z", "--full-name", "--", "."], workingDirectory: directory)
    }

    static func fileHistory(of fileURL: URL, limit: Int) -> GitCommand {
        GitCommand(
            arguments: [
                "log", "--follow", "-z", "--no-color", "--no-show-signature", "--name-status",
                "--max-count=\(limit)", "--format=\(historyFormat)", "--", fileURL.lastPathComponent,
            ],
            workingDirectory: fileURL.deletingLastPathComponent()
        )
    }

    static func blob(revision: String, path: String, in directory: URL) -> GitCommand {
        GitCommand(arguments: ["cat-file", "blob", "--end-of-options", "\(revision):\(path)"], workingDirectory: directory)
    }

    static func currentBranch(in directory: URL) -> GitCommand {
        GitCommand(arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], workingDirectory: directory)
    }

    static func upstreamDivergence(in directory: URL) -> GitCommand {
        GitCommand(
            arguments: ["rev-list", "--left-right", "--count", "--end-of-options", "HEAD...@{upstream}"],
            workingDirectory: directory
        )
    }

    static func changedPaths(from oldCommit: String, to newCommit: String, in directory: URL) -> GitCommand {
        GitCommand(
            arguments: [
                "diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", "--no-textconv",
                "--end-of-options", oldCommit, newCommit, "--",
            ],
            workingDirectory: directory
        )
    }

    static func stage(_ paths: [String], in directory: URL) -> GitCommand {
        GitCommand(
            arguments: ["add", "--"] + paths,
            workingDirectory: directory,
            access: .write,
            timeout: writeTimeout
        )
    }

    static func commit(_ paths: [String], message: String, in directory: URL) -> GitCommand {
        GitCommand(
            arguments: ["commit", "--only", "--message=\(message)", "--"] + paths,
            workingDirectory: directory,
            access: .write,
            timeout: writeTimeout
        )
    }

    static func pull(in directory: URL) -> GitCommand {
        GitCommand(
            arguments: ["pull", "--no-rebase", "--ff-only"],
            workingDirectory: directory,
            access: .write,
            timeout: writeTimeout
        )
    }

    static func push(in directory: URL) -> GitCommand {
        GitCommand(arguments: ["push"], workingDirectory: directory, access: .write, timeout: writeTimeout)
    }
}

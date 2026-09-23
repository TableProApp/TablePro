//
//  GitCommand.swift
//  TablePro
//

import Foundation

internal struct GitCommand: Equatable, Sendable {
    let arguments: [String]
    let workingDirectory: URL

    static let hardeningArguments: [String] = [
        "--no-optional-locks",
        "--no-pager",
        "--literal-pathspecs",
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "color.ui=never",
        "-c", "log.showSignature=false",
        "-c", "safe.bareRepository=explicit",
    ]

    static let environmentOverrides: [String: String] = [
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_PAGER": "cat",
        "GIT_NO_LAZY_FETCH": "1",
    ]

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
        "GIT_EXTERNAL_DIFF",
    ]

    static let historyFormat = "%x1e%H%x1f%an%x1f%aI%x1f%s"

    var processArguments: [String] {
        Self.hardeningArguments + arguments
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

    static func status(in directory: URL, pathspec: String = ".") -> GitCommand {
        GitCommand(
            arguments: ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--find-renames", "--", pathspec],
            workingDirectory: directory
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
}

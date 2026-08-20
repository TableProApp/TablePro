//
//  ProjectFolderFileWalker.swift
//  TablePro
//

import Foundation

struct ProjectScanFile {
    let url: URL
    let relativePath: String
    let match: ProjectConfigFileMatch
}

enum ProjectFolderFileWalker {
    static let maxDepth = 4
    static let maxFileSize = 1_048_576
    static let maxVisitedEntries = 20_000

    private static let excludedDirectories: Set<String> = [
        "node_modules",
        ".git",
        "vendor",
        "venv",
        ".venv",
        "virtualenv",
        "dist",
        "build",
        "target",
        "Pods",
        ".next",
        ".nuxt",
        ".svelte-kit",
        "bower_components",
        ".yarn",
        ".npm",
        ".pnpm-store",
        ".svn",
        ".hg",
        "CVS",
        ".terraform",
        "DerivedData",
        ".gradle",
        ".mvn",
    ]

    static func walk(root: URL, fileManager: FileManager = .default) -> [ProjectScanFile] {
        let rootPath = root.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }
        var files: [ProjectScanFile] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            guard visited <= maxVisitedEntries else {
                break
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            if values.isDirectory == true {
                if shouldSkipDirectory(named: url.lastPathComponent, level: enumerator.level) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let file = scanFile(at: url, values: values, rootPath: rootPath) else {
                continue
            }
            files.append(file)
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    static func isDenied(_ standardizedPath: String) -> Bool {
        deniedPrefixes.contains { standardizedPath == $0 || standardizedPath.hasPrefix($0 + "/") }
    }

    static func relativePath(of standardizedPath: String, rootPath: String) -> String? {
        guard standardizedPath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return String(standardizedPath.dropFirst(rootPath.count + 1))
    }

    private static func scanFile(
        at url: URL,
        values: URLResourceValues,
        rootPath: String
    ) -> ProjectScanFile? {
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            return nil
        }
        guard (values.fileSize ?? 0) <= maxFileSize else {
            return nil
        }
        let standardized = url.standardizedFileURL.path
        guard !isDenied(standardized) else {
            return nil
        }
        guard let relative = relativePath(of: standardized, rootPath: rootPath) else {
            return nil
        }
        guard let match = ProjectConfigFileMatcher.classify(relativePath: relative) else {
            return nil
        }
        return ProjectScanFile(url: url, relativePath: relative, match: match)
    }

    private static func shouldSkipDirectory(named name: String, level: Int) -> Bool {
        if level > maxDepth {
            return true
        }
        if excludedDirectories.contains(name) {
            return true
        }
        return name.hasSuffix(".dist-info")
    }

    private static let deniedPrefixes: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [
            home + "/.ssh",
            home + "/.aws",
            home + "/.gnupg",
            home + "/.docker",
            home + "/Library/Keychains",
            "/etc",
            "/private/etc",
        ]
    }()
}

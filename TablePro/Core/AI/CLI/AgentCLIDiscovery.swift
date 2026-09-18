//
//  AgentCLIDiscovery.swift
//  TablePro
//

import Foundation

struct AgentCLIDiscovery: Sendable {
    let candidatePaths: [String]
    let preferredPathDirectories: [String]

    private let fileManager: @Sendable (String) -> Bool

    init(
        candidatePaths: [String],
        preferredPathDirectories: [String] = AgentCLIDiscovery.defaultPathDirectories,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.candidatePaths = candidatePaths
        self.preferredPathDirectories = preferredPathDirectories
        self.fileManager = isExecutable
    }

    func resolveExecutable(override: String?) -> URL? {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return fileManager(expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        guard let match = candidatePaths.first(where: fileManager) else { return nil }
        return URL(fileURLWithPath: match)
    }

    func makeEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        removingKeys: Set<String> = [],
        adding overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = base
        for key in removingKeys {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = Self.composePath(
            preferred: preferredPathDirectories,
            existing: environment["PATH"] ?? ""
        )
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    static func composePath(preferred: [String], existing: String) -> String {
        let current = existing.split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (preferred + current)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    static var defaultPathDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ] + nodeVersionManagerDirectories(home: home)
    }

    static func nodeVersionManagerDirectories(
        home: String,
        contentsOfDirectory: (String) -> [String] = { path in
            (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        }
    ) -> [String] {
        let nvmVersions = "\(home)/.nvm/versions/node"
        let newest = contentsOfDirectory(nvmVersions)
            .filter { $0.hasPrefix("v") }
            .max { compareVersions($0, $1) == .orderedAscending }
        guard let newest else { return [] }
        return ["\(nvmVersions)/\(newest)/bin"]
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        for index in 0 ..< max(left.count, right.count) {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue != rightValue {
                return leftValue < rightValue ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    private static func versionComponents(_ value: String) -> [Int] {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}

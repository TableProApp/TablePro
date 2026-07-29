//
//  ProjectConfigFileMatcher.swift
//  TablePro
//

import Foundation

enum ProjectConfigFileKind: Sendable {
    case dotenv
    case wordPressConfig
    case prismaSchema
    case springProperties
    case springYaml
    case appSettingsJson
    case railsDatabaseYaml
    case dockerCompose
}

enum ScannedConnectionTier: Int, Comparable, Sendable {
    case nearCertain
    case likelyReal
    case configFile
    case lowValue

    static func < (lhs: ScannedConnectionTier, rhs: ScannedConnectionTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ProjectConfigFileMatch: Sendable {
    let kind: ProjectConfigFileKind
    let tier: ScannedConnectionTier
}

enum ProjectConfigFileMatcher {
    private static let placeholderSuffixes = [".example", ".sample", ".template", ".dist", ".schema"]

    private static let nearCertainDotenvNames: Set<String> = [
        ".env",
        ".env.local",
        ".env.development.local",
        ".env.production.local",
        ".env.test.local",
    ]

    private static let lowValueDotenvNames: Set<String> = [
        ".env.test",
        ".env.testing",
        ".env.defaults",
    ]

    private static let composeNames: Set<String> = [
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
    ]

    static func classify(relativePath: String) -> ProjectConfigFileMatch? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let fileName = components.last, !fileName.isEmpty else {
            return nil
        }
        let parent = components.count >= 2 ? components[components.count - 2].lowercased() : ""
        let lowercased = fileName.lowercased()

        if lowercased == "wp-config.php" {
            return ProjectConfigFileMatch(kind: .wordPressConfig, tier: .configFile)
        }
        if lowercased.hasSuffix(".prisma") {
            return ProjectConfigFileMatch(kind: .prismaSchema, tier: .configFile)
        }
        if isSpringProperties(lowercased) {
            return ProjectConfigFileMatch(kind: .springProperties, tier: .configFile)
        }
        if isSpringYaml(lowercased) {
            return ProjectConfigFileMatch(kind: .springYaml, tier: .configFile)
        }
        if isAppSettings(lowercased) {
            return ProjectConfigFileMatch(kind: .appSettingsJson, tier: .configFile)
        }
        if parent == "config", lowercased == "database.yml" || lowercased == "database.yaml" {
            return ProjectConfigFileMatch(kind: .railsDatabaseYaml, tier: .configFile)
        }
        if isCompose(lowercased) {
            return ProjectConfigFileMatch(kind: .dockerCompose, tier: .configFile)
        }
        if let tier = dotenvTier(fileName) {
            return ProjectConfigFileMatch(kind: .dotenv, tier: tier)
        }
        return nil
    }

    private static func dotenvTier(_ fileName: String) -> ScannedConnectionTier? {
        guard fileName != ".envrc" else {
            return nil
        }
        guard fileName.hasPrefix(".env") || fileName.hasSuffix(".env") else {
            return nil
        }
        let lowercased = fileName.lowercased()
        guard !lowercased.hasSuffix(".bak") else {
            return nil
        }
        guard !placeholderSuffixes.contains(where: { lowercased.hasSuffix($0) }) else {
            return nil
        }
        if nearCertainDotenvNames.contains(lowercased) {
            return .nearCertain
        }
        if lowValueDotenvNames.contains(lowercased) {
            return .lowValue
        }
        return .likelyReal
    }

    private static func isSpringProperties(_ fileName: String) -> Bool {
        if fileName == "application.properties" {
            return true
        }
        return fileName.hasPrefix("application-") && fileName.hasSuffix(".properties")
    }

    private static func isSpringYaml(_ fileName: String) -> Bool {
        if fileName == "application.yml" || fileName == "application.yaml" {
            return true
        }
        guard fileName.hasPrefix("application-") else {
            return false
        }
        return fileName.hasSuffix(".yml") || fileName.hasSuffix(".yaml")
    }

    private static func isAppSettings(_ fileName: String) -> Bool {
        if fileName == "appsettings.json" {
            return true
        }
        return fileName.hasPrefix("appsettings.") && fileName.hasSuffix(".json")
    }

    private static func isCompose(_ fileName: String) -> Bool {
        if composeNames.contains(fileName) {
            return true
        }
        guard fileName.hasPrefix("docker-compose.") || fileName.hasPrefix("compose.") else {
            return false
        }
        return fileName.hasSuffix(".yml") || fileName.hasSuffix(".yaml")
    }
}

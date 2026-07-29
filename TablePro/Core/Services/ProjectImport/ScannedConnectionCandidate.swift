//
//  ScannedConnectionCandidate.swift
//  TablePro
//

import Foundation

struct ScannedConnectionCandidate: Identifiable {
    let id = UUID()
    let parsedURL: ParsedConnectionURL
    let sourceRelativePath: String
    let sourceKey: String
    let kind: ProjectConfigFileKind
    let tier: ScannedConnectionTier
    let placeholderSuspected: Bool
    let warnings: [String]

    var hasPassword: Bool {
        !parsedURL.password.isEmpty
    }

    var displayName: String {
        parsedURL.suggestedName
    }

    init(
        parsedURL: ParsedConnectionURL,
        sourceRelativePath: String,
        sourceKey: String,
        kind: ProjectConfigFileKind,
        tier: ScannedConnectionTier,
        warnings: [String] = []
    ) {
        let isProduction = ScannedProductionHeuristic.isProduction(
            relativePath: sourceRelativePath,
            host: parsedURL.host,
            database: parsedURL.database
        )
        if isProduction, parsedURL.safeModeLevel == nil {
            self.parsedURL = parsedURL.with(safeModeLevel: 1)
        } else {
            self.parsedURL = parsedURL
        }
        self.sourceRelativePath = sourceRelativePath
        self.sourceKey = sourceKey
        self.kind = kind
        self.tier = tier
        self.warnings = warnings
        self.placeholderSuspected = PlaceholderCredentialDetector.isPlaceholder(
            username: parsedURL.username,
            password: parsedURL.password,
            database: parsedURL.database
        )
    }
}

enum PlaceholderCredentialDetector {
    private static let literals: Set<String> = [
        "!changeme!",
        "changeme",
        "change_me",
        "change-me",
        "johndoe",
        "randompassword",
        "username_here",
        "password_here",
        "database_name_here",
        "your_username",
        "your_password",
        "your_database",
        "yourusername",
        "yourpassword",
        "putyourpasswordhere",
    ]

    static func isPlaceholder(username: String, password: String, database: String) -> Bool {
        [username, password, database].contains { literals.contains($0.lowercased()) }
    }
}

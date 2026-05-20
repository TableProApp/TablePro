//
//  RegistryModels.swift
//  TablePro
//

import Foundation

enum PluginArchitecture: String, Codable, Sendable {
    case arm64
    case x86_64

    static var current: PluginArchitecture {
        #if arch(arm64)
        .arm64
        #else
        .x86_64
        #endif
    }
}

struct RegistryBinary: Codable, Sendable {
    let architecture: PluginArchitecture
    let downloadURL: String
    let sha256: String
    let pluginKitVersion: Int?
}

struct RegistryManifest: Codable, Sendable {
    let schemaVersion: Int
    let plugins: [RegistryPlugin]
}

struct RegistryPlugin: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let version: String
    let summary: String
    let author: RegistryAuthor
    let homepage: String?
    let category: RegistryCategory
    let databaseTypeIds: [String]?
    let binaries: [RegistryBinary]
    let minAppVersion: String?
    let iconName: String?
    let isVerified: Bool
    let metadata: RegistryPluginMetadata?

    private let legacyDownloadURL: String?
    private let legacySha256: String?
    private let legacyMinPluginKitVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case id, name, version, summary, author, homepage, category
        case databaseTypeIds, binaries, minAppVersion, iconName, isVerified, metadata
        case legacyDownloadURL = "downloadURL"
        case legacySha256 = "sha256"
        case legacyMinPluginKitVersion = "minPluginKitVersion"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        summary = try container.decode(String.self, forKey: .summary)
        author = try container.decode(RegistryAuthor.self, forKey: .author)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        category = try container.decode(RegistryCategory.self, forKey: .category)
        databaseTypeIds = try container.decodeIfPresent([String].self, forKey: .databaseTypeIds)
        minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
        isVerified = try container.decodeIfPresent(Bool.self, forKey: .isVerified) ?? false
        metadata = try container.decodeIfPresent(RegistryPluginMetadata.self, forKey: .metadata)
        legacyDownloadURL = try container.decodeIfPresent(String.self, forKey: .legacyDownloadURL)
        legacySha256 = try container.decodeIfPresent(String.self, forKey: .legacySha256)
        legacyMinPluginKitVersion = try container.decodeIfPresent(Int.self, forKey: .legacyMinPluginKitVersion)

        if let decodedBinaries = try container.decodeIfPresent([RegistryBinary].self, forKey: .binaries) {
            binaries = decodedBinaries
        } else if let url = legacyDownloadURL, let hash = legacySha256 {
            // v1 manifests carried a single downloadURL with no architecture.
            // Historically those ZIPs shipped a universal binary, so we synthesize
            // entries for both architectures. Code signature verification will
            // reject mismatched arch at install time.
            binaries = [
                RegistryBinary(
                    architecture: .arm64,
                    downloadURL: url,
                    sha256: hash,
                    pluginKitVersion: legacyMinPluginKitVersion
                ),
                RegistryBinary(
                    architecture: .x86_64,
                    downloadURL: url,
                    sha256: hash,
                    pluginKitVersion: legacyMinPluginKitVersion
                )
            ]
        } else {
            binaries = []
        }
    }
}

extension RegistryPlugin {
    func resolvedBinary(
        for arch: PluginArchitecture = .current,
        pluginKitVersion: Int
    ) throws -> RegistryBinary {
        let archMatches = binaries.filter { $0.architecture == arch }

        if let exact = archMatches.first(where: { $0.pluginKitVersion == pluginKitVersion }) {
            return exact
        }

        throw PluginError.noCompatibleBinary
    }

    // Themes carry no native code, so PluginKit ABI does not apply; match on architecture only.
    func resolvedThemeBinary(for arch: PluginArchitecture = .current) throws -> RegistryBinary {
        if let match = binaries.first(where: { $0.architecture == arch }) {
            return match
        }
        if let any = binaries.first {
            return any
        }
        throw PluginError.noCompatibleBinary
    }
}

struct RegistryAuthor: Codable, Sendable {
    let name: String
    let url: String?
}

enum RegistryCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case databaseDriver = "database-driver"
    case exportFormat = "export-format"
    case importFormat = "import-format"
    case theme = "theme"
    case other = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .databaseDriver: String(localized: "Database Drivers")
        case .exportFormat: String(localized: "Export Formats")
        case .importFormat: String(localized: "Import Formats")
        case .theme: String(localized: "Themes")
        case .other: String(localized: "Other")
        }
    }
}

// MARK: - Plugin Metadata (self-describing registry plugins)

struct RegistryPluginMetadata: Codable, Sendable {
    let displayName: String?
    let iconName: String?
    let defaultPort: Int?
    let brandColorHex: String?
    let connectionMode: String?
    let editorLanguage: String?
    let queryLanguageName: String?
    let primaryUrlScheme: String?
    let parameterStyle: String?

    let requiresAuthentication: Bool?
    let supportsForeignKeys: Bool?
    let supportsSchemaEditing: Bool?
    let supportsDatabaseSwitching: Bool?
    let supportsSchemaSwitching: Bool?
    let supportsSSH: Bool?
    let supportsSSL: Bool?
    let supportsImport: Bool?
    let supportsExport: Bool?
    let supportsHealthMonitor: Bool?
    let supportsCascadeDrop: Bool?
    let supportsForeignKeyDisable: Bool?
    let supportsReadOnlyMode: Bool?
    let supportsQueryProgress: Bool?
    let requiresReconnectForDatabaseSwitch: Bool?

    let urlSchemes: [String]?
    let fileExtensions: [String]?
    let systemDatabaseNames: [String]?
    let systemSchemaNames: [String]?
    let defaultSchemaName: String?
    let defaultGroupName: String?
    let tableEntityName: String?
    let defaultPrimaryKeyColumn: String?
    let immutableColumns: [String]?

    let navigationModel: String?
    let pathFieldRole: String?
    let databaseGroupingStrategy: String?
    let structureColumnFields: [String]?
    let postConnectActions: [RegistryPostConnectAction]?
    let additionalConnectionFields: [RegistryConnectionField]?
    let explainVariants: [RegistryExplainVariant]?
    let sqlDialect: RegistrySqlDialect?
    let statementCompletions: [RegistryCompletionEntry]?
    let columnTypesByCategory: [String: [String]]?
}

struct RegistryConnectionField: Codable, Sendable {
    let id: String
    let label: String
    let placeholder: String?
    let defaultValue: String?
    let fieldType: String?
    let section: String?
    let options: [RegistryDropdownOption]?
}

struct RegistryDropdownOption: Codable, Sendable {
    let value: String
    let label: String
}

struct RegistryPostConnectAction: Codable, Sendable {
    let type: String
    let fieldId: String?
}

struct RegistryExplainVariant: Codable, Sendable {
    let name: String
    let prefix: String
}

struct RegistrySqlDialect: Codable, Sendable {
    let identifierQuote: String?
    let keywords: [String]?
    let functions: [String]?
    let dataTypes: [String]?
    let tableOptions: [String]?
    let regexSyntax: String?
    let booleanLiteralStyle: String?
    let likeEscapeStyle: String?
    let paginationStyle: String?
    let offsetFetchOrderBy: String?
    let requiresBackslashEscaping: Bool?
}

struct RegistryCompletionEntry: Codable, Sendable {
    let label: String
    let insertText: String
}

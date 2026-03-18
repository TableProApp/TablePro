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
    let downloadURL: String?
    let sha256: String?
    let binaries: [RegistryBinary]?
    let minAppVersion: String?
    let minPluginKitVersion: Int?
    let iconName: String?
    let isVerified: Bool
    let metadata: RegistryPluginMetadata?
}

extension RegistryPlugin {
    func resolvedBinary(for arch: PluginArchitecture = .current) throws -> (url: String, sha256: String) {
        if let binaries, let match = binaries.first(where: { $0.architecture == arch }) {
            return (match.downloadURL, match.sha256)
        }
        if let url = downloadURL, let hash = sha256 {
            return (url, hash)
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

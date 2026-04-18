//
//  PluginExportTypes.swift
//  TableProPluginKit
//

import Foundation

public struct PluginExportTable: Sendable {
    public let name: String
    public let databaseName: String
    public let tableType: String
    public let optionValues: [Bool]

    public init(name: String, databaseName: String, tableType: String, optionValues: [Bool] = []) {
        self.name = name
        self.databaseName = databaseName
        self.tableType = tableType
        self.optionValues = optionValues
    }

    public var qualifiedName: String {
        databaseName.isEmpty ? name : "\(databaseName).\(name)"
    }
}

public struct PluginExportOptionColumn: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let width: CGFloat
    public let defaultValue: Bool

    public init(id: String, label: String, width: CGFloat, defaultValue: Bool = true) {
        self.id = id
        self.label = label
        self.width = width
        self.defaultValue = defaultValue
    }
}

public enum PluginExportError: LocalizedError {
    case fileWriteFailed(String)
    case encodingFailed
    case compressionFailed
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileWriteFailed(let path):
            return "Failed to write file: \(path)"
        case .encodingFailed:
            return "Failed to encode content as UTF-8"
        case .compressionFailed:
            return "Failed to compress data"
        case .exportFailed(let message):
            return "Export failed: \(message)"
        }
    }
}

public struct PluginExportCancellationError: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "Export cancelled" }
}

public struct PluginSequenceInfo: Sendable {
    public let name: String
    public let ddl: String

    public init(name: String, ddl: String) {
        self.name = name
        self.ddl = ddl
    }
}

public struct PluginEnumTypeInfo: Sendable {
    public let name: String
    public let labels: [String]

    public init(name: String, labels: [String]) {
        self.name = name
        self.labels = labels
    }
}

public struct ExportFormatResult: Sendable {
    public let warnings: [String]
    public init(warnings: [String] = []) {
        self.warnings = warnings
    }
}

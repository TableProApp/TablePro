import Foundation
import SwiftUI

public protocol ExportFormatPlugin: TableProPlugin, Sendable {
    static var formatId: String { get }
    static var formatDisplayName: String { get }
    static var defaultFileExtension: String { get }
    static var iconName: String { get }
    static var supportedDatabaseTypeIds: [String] { get }
    static var excludedDatabaseTypeIds: [String] { get }

    static var perTableOptionColumns: [PluginExportOptionColumn] { get }
    func defaultTableOptionValues() -> [Bool]
    func isTableExportable(optionValues: [Bool]) -> Bool

    /// The object kinds this format can write. A format that does not declare a set receives only
    /// tables and views, which is every kind that existed when the export contract was written.
    static var supportedObjectKinds: [PluginExportObjectKind] { get }

    /// Whether one of `perTableOptionColumns` applies to a kind. The columns stay positionally
    /// aligned with `optionValues` for every kind, so a column a kind does not support is a blank
    /// slot rather than a shifted one: `Data` on a routine, for example.
    static func supportsOption(columnId: String, for kind: PluginExportObjectKind) -> Bool

    /// Whether an object with these option values produces output. Defaults to the table answer,
    /// which is what a format written before object scope will keep giving.
    func isExportable(optionValues: [Bool], kind: PluginExportObjectKind) -> Bool

    var currentFileExtension: String { get }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult
}

public extension ExportFormatPlugin {
    static var capabilities: [PluginCapability] { [.exportFormat] }
    static var supportedDatabaseTypeIds: [String] { [] }
    static var excludedDatabaseTypeIds: [String] { [] }
    static var perTableOptionColumns: [PluginExportOptionColumn] { [] }
    func defaultTableOptionValues() -> [Bool] { [] }
    func isTableExportable(optionValues: [Bool]) -> Bool { true }
    static var supportedObjectKinds: [PluginExportObjectKind] { PluginExportObjectKind.legacyDefault }
    static func supportsOption(columnId: String, for kind: PluginExportObjectKind) -> Bool { true }
    func isExportable(optionValues: [Bool], kind: PluginExportObjectKind) -> Bool {
        isTableExportable(optionValues: optionValues)
    }
    var currentFileExtension: String { Self.defaultFileExtension }
}

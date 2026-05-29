import Foundation
import SwiftUI

public protocol ExportFormatPlugin: TableProPlugin {
    static var formatId: String { get }
    static var formatDisplayName: String { get }
    static var defaultFileExtension: String { get }
    static var iconName: String { get }
    static var supportedDatabaseTypeIds: [String] { get }
    static var excludedDatabaseTypeIds: [String] { get }

    static var perTableOptionColumns: [PluginExportOptionColumn] { get }
    func defaultTableOptionValues() -> [Bool]
    func isTableExportable(optionValues: [Bool]) -> Bool

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
    var currentFileExtension: String { Self.defaultFileExtension }
}

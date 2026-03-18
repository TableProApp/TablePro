//
//  ImportFormatPlugin.swift
//  TableProPluginKit
//

import Foundation
import SwiftUI

public protocol ImportFormatPlugin: TableProPlugin {
    static var formatId: String { get }
    static var formatDisplayName: String { get }
    static var acceptedFileExtensions: [String] { get }
    static var iconName: String { get }
    static var supportedDatabaseTypeIds: [String] { get }
    static var excludedDatabaseTypeIds: [String] { get }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult
}

public extension ImportFormatPlugin {
    static var capabilities: [PluginCapability] { [.importFormat] }
    static var supportedDatabaseTypeIds: [String] { [] }
    static var excludedDatabaseTypeIds: [String] { [] }
}

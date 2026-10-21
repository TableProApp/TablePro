//
//  ImportFormatPlugin.swift
//  TableProPluginKit
//

import Foundation
import SwiftUI

public protocol ImportFormatPlugin: TableProPlugin, Sendable {
    static var formatId: String { get }
    static var formatDisplayName: String { get }
    static var acceptedFileExtensions: [String] { get }
    static var iconName: String { get }
    static var supportedDatabaseTypeIds: [String] { get }
    static var excludedDatabaseTypeIds: [String] { get }
    static var requiresTargetTable: Bool { get }
    static var sourceFieldsFollowFileOrder: Bool { get }

    var fieldDetectionSignature: String { get }

    /// The error handling and transaction options the next import runs with. A host that runs several files in one
    /// transaction reads them first, because the files have to agree. Nil for a format that runs statements.
    var rowImportConfiguration: RowImportRunner.Configuration? { get }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult

    func detectSourceFields(at url: URL, targetTable: String?) throws -> [PluginImportField]
}

public extension ImportFormatPlugin {
    static var capabilities: [PluginCapability] { [.importFormat] }
    static var supportedDatabaseTypeIds: [String] { [] }
    static var excludedDatabaseTypeIds: [String] { [] }
    static var requiresTargetTable: Bool { false }
    static var sourceFieldsFollowFileOrder: Bool { false }

    var fieldDetectionSignature: String { "" }

    var rowImportConfiguration: RowImportRunner.Configuration? { nil }

    func detectSourceFields(at url: URL, targetTable: String?) throws -> [PluginImportField] { [] }
}

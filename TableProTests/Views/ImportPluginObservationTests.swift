//
//  ImportPluginObservationTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class DelimitedImportPlugin: ObservableObject, ImportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Delimited"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Detects fields split on a delimiter"
    static let formatId = "delimited"
    static let formatDisplayName = "Delimited"
    static let acceptedFileExtensions = ["txt"]
    static let iconName = "doc"

    @Published var delimiter = ","

    required init() {}

    var fieldDetectionSignature: String { delimiter }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        PluginImportResult(executedStatements: 0, executionTime: 0)
    }
}

@MainActor
struct ImportPluginObservationTests {
    /// The import sheet holds the plugin through `PluginManager` and its options view is the only
    /// thing that observed the plugin, so picking a new delimiter never redrew the sheet and its
    /// field list stayed on the fields read for the old one.
    @Test("A changed plugin option redraws the import sheet")
    func optionChangeIsRelayed() {
        let plugin = DelimitedImportPlugin()
        let observation = ImportPluginObservation(plugin: plugin)
        var redraws = 0
        let subscription = observation.objectWillChange.sink { redraws += 1 }
        defer { subscription.cancel() }

        plugin.delimiter = ";"

        #expect(redraws == 1)
        #expect(plugin.fieldDetectionSignature == ";")
    }
}

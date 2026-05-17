//
//  PluginManifest.swift
//  TablePro
//

import Foundation

internal struct PluginManifest {
    let bundleId: String
    let providedDatabaseTypeIds: [String]
    let providedExportFormatIds: [String]
    let providedImportFormatIds: [String]
    let providedInspectorIds: [String]
    let providedInspectorFileExtensions: [String]
    let providedInspectorUTIs: [String]

    var supportsLazyLoad: Bool {
        !providedDatabaseTypeIds.isEmpty
            || !providedExportFormatIds.isEmpty
            || !providedImportFormatIds.isEmpty
            || !providedInspectorIds.isEmpty
    }

    init?(bundle: Bundle) {
        guard let id = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        bundleId = id
        providedDatabaseTypeIds = info["TableProProvidesDatabaseTypeIds"] as? [String] ?? []
        providedExportFormatIds = info["TableProProvidesExportFormatIds"] as? [String] ?? []
        providedImportFormatIds = info["TableProProvidesImportFormatIds"] as? [String] ?? []
        providedInspectorIds = info["TableProProvidesInspectorIds"] as? [String] ?? []
        providedInspectorFileExtensions = info["TableProInspectorFileExtensions"] as? [String] ?? []
        providedInspectorUTIs = info["TableProInspectorUTIs"] as? [String] ?? []
    }
}

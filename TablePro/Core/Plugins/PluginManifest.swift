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

    var supportsLazyLoad: Bool {
        !providedDatabaseTypeIds.isEmpty
            || !providedExportFormatIds.isEmpty
            || !providedImportFormatIds.isEmpty
    }

    init?(bundle: Bundle) {
        guard let id = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        bundleId = id
        providedDatabaseTypeIds = info["TableProProvidesDatabaseTypeIds"] as? [String] ?? []
        providedExportFormatIds = info["TableProProvidesExportFormatIds"] as? [String] ?? []
        providedImportFormatIds = info["TableProProvidesImportFormatIds"] as? [String] ?? []
    }
}

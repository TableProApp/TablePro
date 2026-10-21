//
//  MainContentCommandActions+DataDictionary.swift
//  TablePro
//

import Foundation

extension MainContentCommandActions {
    func exportDataDictionary() {
        coordinator?.openExportDataDictionaryDialog()
    }

    // Asks for the one plugin, since listing every format would load each lazily registered one.
    var canExportDataDictionary: Bool {
        guard let plugin = PluginManager.shared.exportPlugin(forFormat: ExportFormatCatalog.dataDictionaryFormatId)
        else { return false }
        let databaseType = currentDatabaseType
        return !ExportFormatCatalog.available(
            [plugin],
            forDatabaseTypeId: databaseType.rawValue,
            listsDatabaseObjects: true,
            columnsAreSampled: databaseType.columnsAreSampled
        ).isEmpty
    }
}

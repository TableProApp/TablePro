//
//  ImportFieldDetection.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// `detectSourceFields` is synchronous and reads the file: the XLSX plugin materialises the whole
/// workbook and the JSON one reads every row. The read runs off the main actor, and cancelling the
/// caller, which the import sheet's task is when the sheet closes, cancels the read with it.
enum ImportFieldDetection {
    static func detectFields(
        plugin: any ImportFormatPlugin,
        at url: URL,
        targetTable: String?
    ) async throws -> [PluginImportField] {
        let detection = Task.detached {
            try plugin.detectSourceFields(at: url, targetTable: targetTable)
        }
        return try await withTaskCancellationHandler {
            try await detection.value
        } onCancel: {
            detection.cancel()
        }
    }
}

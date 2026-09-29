//
//  ImportFieldDetection.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// `detectSourceFields` is synchronous and reads the file: the XLSX plugin materialises the whole
/// workbook and the JSON one reads every row. The read runs off the main actor, and cancelling the
/// caller cancels the read with it. The import sheet's `.task(id:)` cancels its caller when the
/// sheet closes or the read it answers changes, such as another table picked.
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

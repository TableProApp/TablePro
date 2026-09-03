//
//  XLSXImportOptions.swift
//  XLSXImportPlugin
//

import Foundation
import TableProPluginKit

struct XLSXImportOptions: Equatable, Codable {
    var hasHeaderRow: Bool = true
    var trimWhitespace: Bool = false
    var emptyAsNull: Bool = true
    var errorHandling: ImportErrorHandling = .stopAndRollback
    var wrapInTransaction: Bool = true
    var deleteExistingRows: Bool = false

    /// What the mapping sheet keys its cached field detection on. A change to any of these changes
    /// the columns or the values it would infer from, so the cache has to miss.
    var detectionSignature: String {
        [
            hasHeaderRow ? "h1" : "h0",
            trimWhitespace ? "t1" : "t0",
            emptyAsNull ? "n1" : "n0"
        ].joined(separator: "|")
    }
}

//
//  JSONImportOptions.swift
//  JSONImportPlugin
//

import Foundation
import TableProPluginKit

nonisolated struct JSONImportOptions: Equatable, Codable {
    var errorHandling: ImportErrorHandling = .stopAndRollback
    var wrapInTransaction: Bool = true
    var deleteExistingRows: Bool = false
}

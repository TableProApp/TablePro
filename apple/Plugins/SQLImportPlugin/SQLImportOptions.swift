//
//  SQLImportOptions.swift
//  SQLImportPlugin
//

import Foundation
import TableProPluginKit

nonisolated struct SQLImportOptions: Equatable, Codable {
    var errorHandling: ImportErrorHandling = .stopAndRollback
    var wrapInTransaction: Bool = true
    var disableForeignKeyChecks: Bool = true
}

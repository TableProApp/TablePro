//
//  SQLImportOptions.swift
//  SQLImportPlugin
//

import Foundation
import TableProPluginKit

struct SQLImportOptions: Equatable, Codable {
    var errorHandling: ImportErrorHandling = .stopAndRollback
    var wrapInTransaction: Bool = true
    var disableForeignKeyChecks: Bool = true
}

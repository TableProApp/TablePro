//
//  SQLImportOptions.swift
//  SQLImportPlugin
//

import Foundation

struct SQLImportOptions: Equatable, Codable {
    var wrapInTransaction: Bool = true
    var disableForeignKeyChecks: Bool = true
}

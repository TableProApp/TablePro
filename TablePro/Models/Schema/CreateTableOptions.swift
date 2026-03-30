//
//  CreateTableOptions.swift
//  TablePro
//
//  Table-level options for CREATE TABLE generation.
//

import Foundation

struct CreateTableOptions: Hashable {
    var engine: String?
    var charset: String?
    var collation: String?
    var ifNotExists: Bool = false
}

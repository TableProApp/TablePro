//
//  TableOperationOptions.swift
//  TablePro
//
//  Model for table delete/truncate operation options.
//  Supports foreign key constraint handling and cascade operations.
//

import Foundation

/// Options for table delete/truncate operations
struct TableOperationOptions: Codable, Equatable {
    var ignoreForeignKeys: Bool = false
    var cascade: Bool = false
}

/// Type of table operation
enum TableOperationType: String, Codable {
    case truncate
    case drop
}

//
//  LibPQPluginQueryResult.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

struct LibPQPluginQueryResult {
    let columns: [String]
    let columnOids: [UInt32]
    let columnTypeNames: [String]
    let rows: [[PluginCellValue]]
    let affectedRows: Int
    let commandTag: String?
    let isTruncated: Bool

    /// Send to first row, when the read went through single-row mode and could see one. The
    /// buffered `PQexec` path has no such boundary and leaves it nil.
    var firstRowTime: TimeInterval?
}

//
//  ExplainPlanTextFlattener.swift
//  TablePro
//
//  Turns EXPLAIN result rows into the single block of text the plan parsers read. One rule for
//  every entry point, so the Explain action and a hand-typed statement produce identical text.
//

import Foundation
import TableProPluginKit

enum ExplainPlanTextFlattener {
    static func flatten(rows: [[PluginCellValue]]) -> String {
        rows
            .map { row in row.compactMap { $0.asText }.joined(separator: "\t") }
            .joined(separator: "\n")
    }
}

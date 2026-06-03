//
//  ExplainResultRouter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum ExplainResultRouter {
    static func planText(sql: String, columns: [String], rows: [[PluginCellValue]]) -> String? {
        guard QueryClassifier.isExplainStatement(sql), columns.count == 1 else { return nil }
        let text = rows.map { $0.first?.asText ?? "" }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

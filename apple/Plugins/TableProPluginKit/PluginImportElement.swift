//
//  PluginImportElement.swift
//  TableProPluginKit
//

import Foundation

/// One thing a SQL file asks the import to run, in file order.
public enum PluginImportElement: Sendable {
    case statement(String, lineNumber: Int)

    /// A `COPY ... FROM STDIN` and the rows the file holds after it. The rows are read from the file while they are
    /// sent; once the next element is asked for, any left unread are passed over.
    case copyFromStandardInput(statement: String, lineNumber: Int, rows: PluginCopyData)
}

public extension PluginImportElement {
    var statementText: String {
        switch self {
        case .statement(let statement, _), .copyFromStandardInput(let statement, _, _):
            return statement
        }
    }

    var lineNumber: Int {
        switch self {
        case .statement(_, let lineNumber), .copyFromStandardInput(_, let lineNumber, _):
            return lineNumber
        }
    }
}

//
//  GridCopyCommandResponding.swift
//  TablePro
//

import AppKit

// The focused grid answers for its own selection, so these work in any window that shows one; elsewhere they dim.
@MainActor
@objc protocol GridCopyCommandResponding {
    func copyCellValue(_ sender: Any?)
    func copyRowsAsCsv(_ sender: Any?)
    func copyRowsAsCsvWithHeaders(_ sender: Any?)
    func copyRowsAsMarkdown(_ sender: Any?)
    func copyRowsAsInClause(_ sender: Any?)
    func copyRowsAsInsertStatements(_ sender: Any?)
    func copyRowsAsUpdateStatements(_ sender: Any?)
}

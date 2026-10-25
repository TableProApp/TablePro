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

// Copy Rows, Copy with Headers and Copy as JSON. A focused grid answers for its own selection in any window.
@MainActor
@objc protocol GridRowCopyCommandResponding {
    func copySelectedRows(_ sender: Any?)
    func copyRowsWithHeaders(_ sender: Any?)
    func copyRowsAsJson(_ sender: Any?)
}

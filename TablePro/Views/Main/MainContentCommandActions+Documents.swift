//
//  MainContentCommandActions+Documents.swift
//  TablePro
//

import Foundation

extension MainContentCommandActions {
    func insertDocument() {
        coordinator?.presentInsertDocument()
    }

    var canInsertDocument: Bool {
        coordinator?.canInsertDocument ?? false
    }

    func editDocument() {
        guard let displayRow = singleSelectedDataGridRow,
              let locator = coordinator?.documentLocator(forDisplayRow: displayRow) else { return }
        coordinator?.presentEditDocument(locator: locator)
    }

    var canEditDocument: Bool {
        guard let displayRow = singleSelectedDataGridRow else { return false }
        return coordinator?.canEditDocument(atDisplayRow: displayRow) ?? false
    }
}

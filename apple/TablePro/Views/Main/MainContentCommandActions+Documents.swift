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
        guard let rowID = singleSelectedDataGridRowID,
              let locator = coordinator?.documentLocator(for: rowID) else { return }
        coordinator?.presentEditDocument(locator: locator)
    }

    var canEditDocument: Bool {
        guard let rowID = singleSelectedDataGridRowID else { return false }
        return coordinator?.canEditDocument(rowID: rowID) ?? false
    }
}

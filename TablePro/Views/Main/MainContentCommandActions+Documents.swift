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
}

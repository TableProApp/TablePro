//
//  BulkDeleteConfirmation.swift
//  TablePro
//

import Foundation

struct BulkDeleteConfirmation {
    let deletedRowCount: Int

    var isRequired: Bool { deletedRowCount > 0 }

    var title: String {
        deletedRowCount == 1
            ? String(localized: "Delete this row?")
            : String(format: String(localized: "Delete %lld rows?"), deletedRowCount)
    }

    var message: String {
        String(localized: "This permanently deletes the selected rows from the database and can't be undone.")
    }

    var confirmButtonTitle: String {
        String(localized: "Delete")
    }
}

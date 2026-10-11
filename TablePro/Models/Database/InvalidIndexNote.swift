//
//  InvalidIndexNote.swift
//  TablePro
//

import Foundation

internal struct InvalidIndexNote: Equatable {
    internal let systemImage = "exclamationmark.triangle"
    internal let text: String

    internal init?(indexes: [IndexInfo]) {
        let names = indexes.filter { !$0.isValid }.map(\.name)
        guard !names.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: names)
        let format = names.count == 1
            ? String(localized: "%@ is invalid, so queries skip it and exports leave it out. Drop it, or rebuild it with REINDEX.")
            : String(localized: "%@ are invalid, so queries skip them and exports leave them out. Drop them, or rebuild them with REINDEX.")
        text = String(format: format, list)
    }
}

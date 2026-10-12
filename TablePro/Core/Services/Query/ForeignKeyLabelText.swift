//
//  ForeignKeyLabelText.swift
//  TablePro
//

import Foundation

/// The one line a picker row shows beside its key, built from the chosen label columns.
enum ForeignKeyLabelText {
    static let separator = ", "

    /// A NULL or empty column is dropped rather than rendered as a gap, so a row missing the
    /// middle value of three reads `integrale, caputo` instead of `integrale, , caputo`. A row
    /// whose every chosen column is NULL carries no label at all, which is what the key-only
    /// list already looks like.
    static func joined(_ values: [String?]) -> String? {
        let present = values.compactMap { $0 }.filter { !$0.isEmpty }
        guard !present.isEmpty else { return nil }
        return present.joined(separator: separator)
    }
}

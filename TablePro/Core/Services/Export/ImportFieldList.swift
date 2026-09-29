//
//  ImportFieldList.swift
//  TablePro
//

import Foundation

/// What a field list in the import sheet is read for: the table its fields are matched against,
/// if any, the plugin options that shape detection, and the Try Again it answers.
struct ImportFieldDetectionRequest: Hashable {
    let targetTable: String?
    let detectionSignature: String
    let attempt: Int
}

/// A field list together with the request it was read for.
///
/// The rows answer that request and no other, so a change to any part of it, an option that
/// shapes detection included, reads the file again. The request travels with the rows because a
/// separate "loaded" flag, cleared from `onChange`, was cleared after the `.task(id:)` that read
/// it: SwiftUI ran the restarted task first, and the fields of the old options stayed on screen.
struct ImportFieldList<Row> {
    var rows: [Row] = []
    private(set) var readFor: ImportFieldDetectionRequest?

    func needsRead(for request: ImportFieldDetectionRequest) -> Bool {
        readFor != request
    }

    /// Empties the list ahead of a read for another request. The request goes with the rows, or a
    /// return to it before the read finished would find it answered and show an empty list.
    mutating func discard() {
        rows = []
        readFor = nil
    }

    mutating func finishRead(_ rows: [Row], for request: ImportFieldDetectionRequest) {
        self.rows = rows
        readFor = request
    }
}

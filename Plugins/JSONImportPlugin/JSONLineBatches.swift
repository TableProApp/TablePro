//
//  JSONLineBatches.swift
//  JSONImportPlugin
//

import Foundation
import TableProPluginKit

/// Hands the rows of a JSON Lines file to `RowImportRunner` one batch at a time, and keeps the
/// lines Skip and Continue passed over.
///
/// A batch ends after a set number of lines, not rows. The runner checks for a stop between
/// batches, so a batch that waited for its rows read on through a run of lines holding none, up
/// to a whole chunk of the file, before a stop was seen.
struct JSONLineBatches {
    private var lines: JSONLineReader
    private let linesPerBatch: Int
    private let skipsUnreadableLines: Bool
    private let maxRecordedErrors: Int

    private(set) var unreadableLines: [PluginImportResult.ImportStatementError] = []

    /// Every unreadable line, counted past the end of the capped `unreadableLines` list.
    private(set) var unreadableLineCount = 0

    var linesRead: Int { lines.lineNumber }

    init(lines: JSONLineReader, linesPerBatch: Int, skipsUnreadableLines: Bool, maxRecordedErrors: Int) {
        self.lines = lines
        self.linesPerBatch = max(1, linesPerBatch)
        self.skipsUnreadableLines = skipsUnreadableLines
        self.maxRecordedErrors = maxRecordedErrors
    }

    mutating func next() throws -> [RowImportRunner.Entry]? {
        var batch: [RowImportRunner.Entry] = []
        var linesInBatch = 0
        while linesInBatch < linesPerBatch, let line = try lines.next() {
            linesInBatch += 1
            let lineNumber = lines.lineNumber
            do {
                let row = try autoreleasepool { try JSONImportParsing.parseRow(fromLine: line) }
                guard let row, !row.isEmpty else { continue }
                batch.append((lineNumber, row))
            } catch {
                guard skipsUnreadableLines else { throw error }
                recordUnreadableLine(lineNumber, error: error)
            }
        }
        return linesInBatch == 0 ? nil : batch
    }

    func close() {
        lines.close()
    }

    private mutating func recordUnreadableLine(_ lineNumber: Int, error: any Error) {
        unreadableLineCount += 1
        guard unreadableLines.count < maxRecordedErrors else { return }
        unreadableLines.append(.init(
            statement: "row \(lineNumber)",
            line: lineNumber,
            errorMessage: error.localizedDescription
        ))
    }
}

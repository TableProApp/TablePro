//
//  SQLImportCopyRows.swift
//  SQLImportPlugin
//

import Foundation
import TableProPluginKit

// The driver pulls a COPY's rows on its own thread, so the check for a Stop and the progress note ride on each pull.
internal final class SQLImportCopyRows: @unchecked Sendable {
    private static let lineFeed = UInt8(ascii: "\n")
    private static let linesPerNote = 10_000

    private let rows: PluginCopyData
    private let line: Int
    private let progress: PluginImportProgress
    private let lock = NSLock()
    private var linesSent = 0
    private var linesNoted: Int?

    private init(_ rows: PluginCopyData, line: Int, progress: PluginImportProgress) {
        self.rows = rows
        self.line = line
        self.progress = progress
    }

    internal static func watching(_ rows: PluginCopyData, line: Int, progress: PluginImportProgress) -> PluginCopyData {
        let watched = SQLImportCopyRows(rows, line: line, progress: progress)
        return PluginCopyData { try watched.nextPiece() }
    }

    private func nextPiece() throws -> Data? {
        try progress.checkCancellation()
        guard let piece = try rows.nextPiece() else { return nil }
        let lines = piece.reduce(into: 0) { count, byte in
            if byte == Self.lineFeed { count += 1 }
        }
        let note = lock.withLock { () -> Int? in
            linesSent += lines
            guard linesNoted.map({ linesSent - $0 >= Self.linesPerNote }) ?? true else { return nil }
            linesNoted = linesSent
            return linesSent
        }
        if let note {
            progress.setStatus(String(
                format: String(localized: "COPY at line %@: %@ lines sent"),
                line.formatted(),
                note.formatted()
            ))
        }
        return piece
    }
}

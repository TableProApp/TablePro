//
//  BackupOutcomeRow.swift
//  TablePro
//

import Foundation

/// One database's line in the backup result sheet.
///
/// A row rather than a line of text, because the sheet used to join the destination folder and one
/// sentence per database into a single monospaced block: a folder ending in `New/` above a database
/// called `Music` read as the one path `/Users/Nick/Music/New/Music` (#3046).
struct BackupOutcomeRow: Identifiable, Equatable {
    enum State: Equatable {
        case succeeded
        case failed
        case cancelled
    }

    let id: String
    let database: String
    let state: State
    /// The size for a database that was written, and the file's name under it.
    let fileName: String
    let size: String?
    /// Everything the tool said, kept whole. The last line alone is not the diagnosis: `pg_dump`
    /// ends a refused connection with "Is the server running on that host…" and a permission
    /// failure with "detail: Query was: LOCK TABLE …", and the cause is the line above.
    let errorDetail: String?

    static func rows(for outcomes: [NativeDumpBatchOutcome]) -> [BackupOutcomeRow] {
        outcomes.map { outcome in
            switch outcome.result {
            case .succeeded(let bytes):
                return BackupOutcomeRow(
                    id: outcome.destination.path,
                    database: outcome.database,
                    state: .succeeded,
                    fileName: outcome.destination.lastPathComponent,
                    size: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                    errorDetail: nil
                )
            case .failed(let message):
                return BackupOutcomeRow(
                    id: outcome.destination.path,
                    database: outcome.database,
                    state: .failed,
                    fileName: outcome.destination.lastPathComponent,
                    size: nil,
                    errorDetail: message.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            case .cancelled:
                return BackupOutcomeRow(
                    id: outcome.destination.path,
                    database: outcome.database,
                    state: .cancelled,
                    fileName: outcome.destination.lastPathComponent,
                    size: nil,
                    errorDetail: nil
                )
            }
        }
    }
}

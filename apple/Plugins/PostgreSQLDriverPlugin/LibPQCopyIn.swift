//
//  LibPQCopyIn.swift
//  PostgreSQLDriverPlugin
//

import CLibPQ
import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

/// Sends a `COPY ... FROM STDIN` its rows, after the statement answered `PGRES_COPY_IN`, the way psql 18 sends a
/// script's rows: the data as `CopyData`, never the `\.` line, then `CopyDone`. Measured with libpq 17.4 against
/// PostgreSQL 17.11 and 18.6 (`apple/scripts/probes/check-postgresql-copy-in.sh`).
nonisolated enum LibPQCopyIn {
    struct Sent {
        // The copy's own result, or nil when libpq had none to give. The caller clears it.
        let result: OpaquePointer?
        // Why the rows stopped before their end, when they did.
        let interruption: Interruption?
    }

    enum Interruption {
        case cancelled
        case binaryFormat
        case source(Error)
        case connection
    }

    // psql's own CopyFail reasons, which the server echoes as "COPY from stdin failed: <reason>".
    static let cancelledReason = "canceled by user"
    static let sourceFailedReason = "aborted because of read failure"
    static let binaryReason = "binary COPY data cannot come from a script"

    static var binaryRefusal: String {
        String(localized: "A script cannot hold binary COPY data, so no rows were sent. Dump the rows as text or CSV.")
    }

    // PQputCopyData takes an `int` length and grows its buffer to hold a whole message.
    private static let sliceLength = 1 << 20

    static func send(
        _ rows: PluginCopyData,
        format: LibPQCopyFormat,
        conn: OpaquePointer,
        isCancelled: () -> Bool
    ) -> Sent {
        // A script holds text, and psql would send the rest of the file as the binary stream.
        let interruption: Interruption? = format == .binary
            ? .binaryFormat
            : sendPieces(rows, conn: conn, isCancelled: isCancelled)
        let ended: Int32
        switch interruption {
        case nil:
            ended = PQputCopyEnd(conn, nil)
        case .connection:
            ended = -1
        case .cancelled:
            ended = cancelledReason.withCString { PQputCopyEnd(conn, $0) }
        case .binaryFormat:
            ended = binaryReason.withCString { PQputCopyEnd(conn, $0) }
        case .source(let error):
            let reason = isStop(error) ? cancelledReason : sourceFailedReason
            ended = reason.withCString { PQputCopyEnd(conn, $0) }
        }
        let reported = ended == 1 ? interruption : (interruption ?? .connection)
        return Sent(result: finalResult(conn), interruption: reported)
    }

    private static func sendPieces(_ rows: PluginCopyData, conn: OpaquePointer, isCancelled: () -> Bool) -> Interruption? {
        do {
            while true {
                if isCancelled() { return .cancelled }
                guard let piece = try rows.nextPiece() else { return nil }
                guard put(piece, conn: conn) else { return .connection }
            }
        } catch {
            return .source(error)
        }
    }

    // An import's Stop reaches here as its source's throw, and the server log should read it as one.
    private static func isStop(_ error: Error) -> Bool {
        error is PluginImportCancellationError || error is CancellationError
    }

    private static func put(_ piece: Data, conn: OpaquePointer) -> Bool {
        piece.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return true }
            var offset = 0
            while offset < raw.count {
                let length = min(sliceLength, raw.count - offset)
                guard PQputCopyData(conn, base + offset, Int32(length)) == 1 else { return false }
                offset += length
            }
            return true
        }
    }

    // While libpq still answers PGRES_COPY_IN the copy is not over: end it again, as psql does. The first other
    // result is the copy's; the rest are drained so the connection takes the next statement.
    private static func finalResult(_ conn: OpaquePointer) -> OpaquePointer? {
        var copyResult: OpaquePointer?
        var endsAgain = 0
        while let next = PQgetResult(conn) {
            guard PQresultStatus(next) != PGRES_COPY_IN else {
                PQclear(next)
                endsAgain += 1
                guard endsAgain <= 3 else { break }
                _ = "trying to exit copy mode".withCString { PQputCopyEnd(conn, $0) }
                continue
            }
            if copyResult == nil {
                copyResult = next
            } else {
                PQclear(next)
            }
        }
        return copyResult
    }
}

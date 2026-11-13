//
//  LibPQCopyIn.swift
//  PostgreSQLDriverPlugin
//

import CLibPQ
import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

/// Sends a `COPY ... FROM STDIN` its rows the way psql 18 sends a script's rows: the data as `CopyData`, never the
/// `\.` line, then `CopyDone`. Measured with libpq 17.4 against PostgreSQL 17.11 and 18.6
/// (`apple/scripts/probes/check-postgresql-copy-in.sh`).
///
/// The connection is nonblocking from the statement to its result and every wait is a slice, so a Stop is seen while
/// the server takes no data. A Stop ends the rows with `CopyFail`; when the server has not answered a slice later
/// (a row lock wait, or rows a proxy still holds), one cancel request follows from this thread, so it has reached the
/// server before the results are read and cannot stop the statement after the COPY.
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

    // Read on the connection's queue only, for one COPY.
    final class Stop {
        private let requested: () -> Bool
        private let closing: () -> Bool
        private let sendCancelRequest: () -> Void
        private var sentCancelRequest = false

        init(requested: @escaping () -> Bool, closing: @escaping () -> Bool, sendCancelRequest: @escaping () -> Void) {
            self.requested = requested
            self.closing = closing
            self.sendCancelRequest = sendCancelRequest
        }

        var isRequested: Bool { requested() }
        var isClosing: Bool { closing() }

        func cancelServerOnce() {
            guard !sentCancelRequest else { return }
            sentCancelRequest = true
            sendCancelRequest()
        }
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
    private static let waitMicroseconds: Int64 = 100_000

    /// The statement's result as `PQexec` gives it: the last one, or the first that starts a copy. Nil when the
    /// connection was lost. The connection stays nonblocking only after `PGRES_COPY_IN`, for `send`.
    static func begin(_ statement: String, conn: OpaquePointer, stop: Stop) -> OpaquePointer? {
        guard PQsetnonblocking(conn, 1) == 0, statement.withCString({ PQsendQuery(conn, $0) }) == 1 else {
            _ = PQsetnonblocking(conn, 0)
            return nil
        }
        var last: OpaquePointer?
        // Nothing to retract while the statement starts, so a Stop sends the cancel request at once.
        while awaitResult(conn, stop: stop, patience: 0) == .ready, let next = PQgetResult(conn) {
            PQclear(last)
            last = next
            let status = PQresultStatus(next)
            if status == PGRES_COPY_IN || status == PGRES_COPY_OUT || status == PGRES_COPY_BOTH
                || PQstatus(conn) == CONNECTION_BAD {
                break
            }
        }
        if last.map({ PQresultStatus($0) != PGRES_COPY_IN }) ?? true {
            _ = PQsetnonblocking(conn, 0)
        }
        return last
    }

    /// After `begin` answered `PGRES_COPY_IN`. Returns with the connection blocking again.
    static func send(_ rows: PluginCopyData, format: LibPQCopyFormat, conn: OpaquePointer, stop: Stop) -> Sent {
        // A script holds text, and psql would send the rest of the file as the binary stream.
        let interruption: Interruption? = format == .binary ? .binaryFormat : sendPieces(rows, conn: conn, stop: stop)
        let ended: Int32
        let stopped: Bool
        switch interruption {
        case nil:
            ended = PQputCopyEnd(conn, nil)
            stopped = false
        case .connection:
            ended = -1
            stopped = false
        case .cancelled:
            ended = cancelledReason.withCString { PQputCopyEnd(conn, $0) }
            stopped = true
        case .binaryFormat:
            ended = binaryReason.withCString { PQputCopyEnd(conn, $0) }
            stopped = false
        case .source(let error):
            stopped = isStop(error)
            ended = (stopped ? cancelledReason : sourceFailedReason).withCString { PQputCopyEnd(conn, $0) }
        }
        // A CopyFail can still be answered on its own, so the cancel request waits a slice; after CopyDone it cannot.
        let answered = ended == 1
            && awaitResult(conn, stop: stop, patience: interruption == nil ? 0 : 1, stopped: stopped) == .ready
        _ = PQsetnonblocking(conn, 0)
        guard answered else {
            return Sent(result: nil, interruption: interruption ?? .connection)
        }
        return Sent(result: finalResult(conn), interruption: interruption)
    }

    private static func sendPieces(_ rows: PluginCopyData, conn: OpaquePointer, stop: Stop) -> Interruption? {
        do {
            while true {
                if stop.isRequested { return .cancelled }
                guard let piece = try rows.nextPiece() else { return nil }
                guard put(piece, conn: conn) else { return .connection }
                switch flush(conn, stop: stop) {
                case .sent: continue
                case .stopped: return .cancelled
                case .lost: return .connection
                }
            }
        } catch {
            return .source(error)
        }
    }

    // An import's Stop reaches here as its source's throw, and the server log should read it as one.
    private static func isStop(_ error: Error) -> Bool {
        error is PluginImportCancellationError || error is CancellationError
    }

    // Nonblocking, so each slice only queues it: `flush` sends it.
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

    private enum Flush {
        case sent
        case stopped
        case lost
    }

    private static func flush(_ conn: OpaquePointer, stop: Stop) -> Flush {
        while true {
            let flushed = PQflush(conn)
            guard flushed >= 0, !stop.isClosing, PQstatus(conn) != CONNECTION_BAD else { return .lost }
            if flushed == 0 { return .sent }
            if stop.isRequested { return .stopped }
            guard wait(conn, forWrite: true) else { return .lost }
            // The server's notices, so it never blocks writing to us while we wait to write to it.
            _ = PQconsumeInput(conn)
        }
    }

    private enum Answer {
        case ready
        case lost
    }

    // Until libpq holds a result and has sent everything queued. A proxy can take every byte while the server reads
    // none, so this is the wait that tells such a server. `patience` is how many slices a Stop waits before its
    // cancel request goes.
    private static func awaitResult(_ conn: OpaquePointer, stop: Stop, patience: Int, stopped: Bool = false) -> Answer {
        var unanswered = 0
        while true {
            let flushed = PQflush(conn)
            guard flushed >= 0, !stop.isClosing else { return .lost }
            if flushed == 0, PQisBusy(conn) == 0 { return .ready }
            if stopped || stop.isRequested {
                if unanswered >= patience { stop.cancelServerOnce() }
                unanswered += 1
            }
            guard wait(conn, forWrite: flushed == 1) else { return .lost }
            // A failed read leaves the connection bad, and PQgetResult then gives the reason.
            if PQconsumeInput(conn) == 0, PQisBusy(conn) == 0 { return .ready }
        }
    }

    private static func wait(_ conn: OpaquePointer, forWrite: Bool) -> Bool {
        let socket = PQsocket(conn)
        guard socket >= 0 else { return false }
        let deadline = pg_usec_time_t(Int64(PQgetCurrentTimeUSec()) + waitMicroseconds)
        return PQsocketPoll(socket, 1, forWrite ? 1 : 0, deadline) >= 0 || errno == EINTR
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

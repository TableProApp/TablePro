//
//  LibPQCopyState.swift
//  PostgreSQLDriverPlugin
//

import CLibPQ
import Foundation

nonisolated enum LibPQCopyState {
    static let unsentInputReason = "no COPY data was sent"

    static func copy(of result: OpaquePointer) -> LibPQCopy? {
        guard let direction = direction(of: PQresultStatus(result)) else { return nil }
        return LibPQCopy(direction: direction, format: PQbinaryTuples(result) == 1 ? .binary : .textual)
    }

    static func direction(of status: ExecStatusType) -> LibPQCopyDirection? {
        switch status {
        case PGRES_COPY_IN: return .copyIn
        case PGRES_COPY_OUT: return .copyOut
        case PGRES_COPY_BOTH: return .copyBoth
        default: return nil
        }
    }

    static func finishPendingResults(_ conn: OpaquePointer, cancellingOutput: Bool) -> LibPQDrainOutcome {
        LibPQPendingResultDrain.drain(
            nextResult: {
                guard let result = PQgetResult(conn) else { return nil }
                defer { PQclear(result) }
                return copy(of: result).map(LibPQPendingResult.copy) ?? .completed
            },
            endCopy: { end($0, conn: conn, cancellingOutput: cancellingOutput) }
        )
    }

    /// A textual or CSV `COPY FROM STDIN` ends with CopyDone, which completes the statement with
    /// zero rows and leaves an open transaction in `INTRANS`. CopyFail aborts the transaction, so
    /// it is kept for binary input alone, where CopyDone fails on the missing file signature.
    /// Measured on 9.1.24 and 17.11.
    static func end(_ copy: LibPQCopy, conn: OpaquePointer, cancellingOutput: Bool) {
        switch copy.direction {
        case .copyIn:
            endInput(copy, conn: conn)
        case .copyOut:
            discardOutput(conn, cancelling: cancellingOutput)
        case .copyBoth:
            endInput(copy, conn: conn)
            discardOutput(conn, cancelling: cancellingOutput)
        }
    }

    private static func endInput(_ copy: LibPQCopy, conn: OpaquePointer) {
        guard copy.format == .binary else {
            _ = PQputCopyEnd(conn, nil)
            return
        }
        _ = unsentInputReason.withCString { PQputCopyEnd(conn, $0) }
    }

    private static func discardOutput(_ conn: OpaquePointer, cancelling: Bool) {
        if cancelling { cancelStatement(conn) }
        var buffer: UnsafeMutablePointer<CChar>?
        while PQgetCopyData(conn, &buffer, 0) > 0 {
            PQfreemem(buffer)
            buffer = nil
        }
    }

    private static func cancelStatement(_ conn: OpaquePointer) {
        guard let cancelObject = PQgetCancel(conn) else { return }
        defer { PQfreeCancel(cancelObject) }
        var errbuf = [CChar](repeating: 0, count: 256)
        PQcancel(cancelObject, &errbuf, Int32(errbuf.count))
    }
}

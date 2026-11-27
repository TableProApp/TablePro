//
//  LibPQRowMode.swift
//  PostgreSQLDriverPlugin
//

import CLibPQ

// How every read takes its rows from libpq: in chunks of up to `chunkRows`, one `PGresult` per chunk. Single-row
// mode builds, copies the column descriptors into, and frees a whole `PGresult` per row. Measured on 1M rows x 20
// columns against PostgreSQL 17 with the bundled libpq 17.4: 1.35-1.64 s of client CPU in single-row mode, 1.0-1.1 s
// at 4 rows, 0.90-0.93 s at 8, and no further gain at 16, 256 or 1,024; at 250 columns, 0.80 s against 0.50 s per
// 50k rows at 8.
// libpq hands a chunk over only once it is full or the result ends, and holds every raw row of it until then, so the
// chunk stays small: at worst it holds `chunkRows` of the widest rows where single-row mode held one. A read with a byte
// limit exists to bound that, so it keeps single-row mode. The server buffers its own output, so a slow query's first
// rows arrive no later than they did one at a time.
enum LibPQRowMode {
    static let chunkRows: Int32 = 8

    // Right after the send, before any result is read; libpq refuses either mode after that. Single-row mode is also
    // the fallback for a libpq that refuses chunks, since it hands over the same rows one at a time.
    static func enter(_ conn: OpaquePointer, chunked: Bool = true) -> Bool {
        (chunked && PQsetChunkedRowsMode(conn, chunkRows) == 1) || PQsetSingleRowMode(conn) == 1
    }

    // A result that holds some of a statement's rows, with more to follow. The one that ends the rows is
    // `PGRES_TUPLES_OK` with none of its own.
    static func carriesRows(_ status: ExecStatusType) -> Bool {
        status == PGRES_TUPLES_CHUNK || status == PGRES_SINGLE_TUPLE
    }
}

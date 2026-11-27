//
//  PluginCopyData.swift
//  TableProPluginKit
//

import Foundation

/// The rows a `COPY ... FROM STDIN` loads, handed over a piece at a time so a large block is never held whole.
///
/// The driver pulls each piece on the thread that holds its connection for the whole copy, so a read may block on a
/// file. A piece can end anywhere, inside a row too, and holds row data only: never psql's `\.` line.
public struct PluginCopyData: Sendable {
    private let read: @Sendable () throws -> Data?

    public init(read: @escaping @Sendable () throws -> Data?) {
        self.read = read
    }

    /// The next piece, encoded for the session (UTF-8 here), or nil once every row was read. A throw ends the copy
    /// with a failure, so the server keeps none of its rows, and the driver rethrows it.
    public func nextPiece() throws -> Data? {
        try read()
    }
}

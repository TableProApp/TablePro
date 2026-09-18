import Foundation

/// Turns an incremental row stream into a capped `PluginQueryResult` without reading past the cap.
///
/// Truncation is decided by a batch overflowing the cap rather than by holding a row past it, so
/// `isTruncated` tells "there were exactly `rowCap` rows" apart from "there were more" without the
/// collector ever keeping the extra row. A driver that bounds its own fetch has to read one row
/// past the cap to draw the same distinction.
public enum PluginBoundedStream {
    @_disfavoredOverload
    public static func collect(
        _ stream: AsyncThrowingStream<PluginStreamElement, Error>,
        rowCap: Int,
        startedAt: Date
    ) async throws -> PluginQueryResult {
        try await collect(stream, rowCap: rowCap, startedAt: startedAt, serverElapsed: nil)
    }

    /// `serverElapsed` is the engine's own report where its protocol carries one. Streaming
    /// responses often send it as a trailer the client never sees, so it stays optional.
    public static func collect(
        _ stream: AsyncThrowingStream<PluginStreamElement, Error>,
        rowCap: Int,
        startedAt: Date,
        serverElapsed: TimeInterval?
    ) async throws -> PluginQueryResult {
        let cap = max(rowCap, 1)
        var columns: [String] = []
        var columnTypeNames: [String] = []
        var rows: [PluginRow] = []
        rows.reserveCapacity(min(cap, 10_000))
        var truncated = false
        /// The first batch to arrive is the first row the server produced, which is the only part
        /// of a streamed read that separates the query's own cost from the cost of moving its rows.
        var firstRowTime: TimeInterval?

        for try await element in stream {
            switch element {
            case .header(let header):
                columns = header.columns
                columnTypeNames = header.columnTypeNames
            case .rows(let batch):
                if firstRowTime == nil, !batch.isEmpty {
                    firstRowTime = Date().timeIntervalSince(startedAt)
                }
                let remaining = cap - rows.count
                if batch.count > remaining {
                    rows.append(contentsOf: batch.prefix(remaining))
                    truncated = true
                } else {
                    rows.append(contentsOf: batch)
                }
            }
            if truncated { break }
        }

        return PluginQueryResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: 0,
            timing: PluginQueryTiming(
                total: Date().timeIntervalSince(startedAt),
                firstRow: firstRowTime ?? Date().timeIntervalSince(startedAt),
                server: serverElapsed
            ),
            isTruncated: truncated
        )
    }
}

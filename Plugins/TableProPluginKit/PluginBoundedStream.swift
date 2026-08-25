import Foundation

/// Turns an incremental row stream into a capped `PluginQueryResult` without reading past the cap.
///
/// Truncation is decided by a batch overflowing the cap rather than by holding a row past it, so
/// `isTruncated` tells "there were exactly `rowCap` rows" apart from "there were more" without the
/// collector ever keeping the extra row. A driver that bounds its own fetch has to read one row
/// past the cap to draw the same distinction.
public enum PluginBoundedStream {
    public static func collect(
        _ stream: AsyncThrowingStream<PluginStreamElement, Error>,
        rowCap: Int,
        startedAt: Date
    ) async throws -> PluginQueryResult {
        let cap = max(rowCap, 1)
        var columns: [String] = []
        var columnTypeNames: [String] = []
        var rows: [PluginRow] = []
        rows.reserveCapacity(min(cap, 10_000))
        var truncated = false

        for try await element in stream {
            switch element {
            case .header(let header):
                columns = header.columns
                columnTypeNames = header.columnTypeNames
            case .rows(let batch):
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
            executionTime: Date().timeIntervalSince(startedAt),
            isTruncated: truncated
        )
    }
}

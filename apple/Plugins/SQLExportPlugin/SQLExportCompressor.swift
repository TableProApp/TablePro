//
//  SQLExportCompressor.swift
//  SQLExportPlugin
//

import Foundation
import TableProGzip
import TableProPluginKit

// Compresses through the atomic pair, so a failed or stopped compression leaves the previous file whole (#2533).
nonisolated internal enum SQLExportCompressor {
    // Often enough that whoever watches the status sees the run move, rarely enough to cost nothing.
    private static let statusInterval = Duration.milliseconds(250)

    @concurrent
    internal static func compress(
        source: URL,
        to destination: URL,
        progress: PluginExportProgress
    ) async throws {
        try progress.checkCancellation()

        let (handle, tempURL) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        var committed = false
        defer {
            if !committed { PluginExportUtilities.rollbackAtomicWrite(at: tempURL) }
        }

        let clock = ContinuousClock()
        var lastStatus: ContinuousClock.Instant?
        do {
            try GzipFile.compress(source: source, into: handle, isCancelled: { progress.isCancelled }) { done, total in
                let now = clock.now
                if done < total, let lastStatus, now - lastStatus < Self.statusInterval { return }
                lastStatus = now
                progress.setStatus(Self.status(done: done, total: total))
            }
        } catch is CancellationError {
            try? handle.close()
            throw PluginExportCancellationError()
        } catch {
            try? handle.close()
            throw error
        }
        // A volume can report a deferred write failure only at close, and a swallowed one would let a truncated temp
        // replace a valid dump.
        try handle.close()
        // A Stop that lands after the last chunk still abandons the file.
        try progress.checkCancellation()
        try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: destination)
        committed = true
    }

    private static func status(done: Int64, total: Int64) -> String {
        String(
            format: String(localized: "Compressing\u{2026} %1$@ of %2$@"),
            ByteCountFormatter.string(fromByteCount: done, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        )
    }
}

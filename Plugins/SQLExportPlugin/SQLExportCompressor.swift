//
//  SQLExportCompressor.swift
//  SQLExportPlugin
//

import Foundation
import TableProPluginKit

/// Compresses a finished dump into the file the user named, through the atomic pair the
/// uncompressed export already writes through.
///
/// Two defects lived in the code this replaces. `FileManager.createFile(atPath:contents:)` truncates
/// an existing file to zero and still returns true, so a compressed export aimed at a file that was
/// already there emptied it before gzip had produced a byte, and a failure or a Stop then removed
/// the stump: measured, a 22-byte `dump.sql.gz` became 0 bytes and was then deleted, while the
/// uncompressed path left the previous dump untouched. And Stop did nothing at all, because the only
/// cancellation it watched was `Task.isCancelled` and nothing cancels the task an export runs in;
/// `Progress.cancel()` is the channel Stop actually writes. (#2533)
internal enum SQLExportCompressor {
    private static let gzipPath = "/usr/bin/gzip"

    /// Stop writes `Progress.cancel()`, which is not a task cancellation, so it has to be polled.
    /// Short enough that Stop reads as immediate against a compression measured in hundreds of
    /// milliseconds, long enough to cost nothing over a long one.
    private static let cancellationPollInterval = Duration.milliseconds(150)

    internal static func compress(
        source: URL,
        to destination: URL,
        progress: PluginExportProgress
    ) async throws {
        guard FileManager.default.isExecutableFile(atPath: gzipPath) else {
            throw PluginExportError.exportFailed(
                String(format: String(localized: "Compression unavailable: gzip not found at %@"), gzipPath))
        }
        try progress.checkCancellation()

        let (handle, tempURL) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        var committed = false
        defer {
            if !committed { PluginExportUtilities.rollbackAtomicWrite(at: tempURL) }
        }

        try await runGzip(source: source, into: handle, progress: progress)
        try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: destination)
        committed = true
    }

    private static func runGzip(
        source: URL,
        into handle: FileHandle,
        progress: PluginExportProgress
    ) async throws {
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gzipPath)
        process.arguments = ["-c", source.standardizedFileURL.path(percentEncoded: false)]
        process.standardOutput = handle
        process.standardError = errorPipe

        let gate = ProcessGate()
        let watcher = Task {
            while !Task.isCancelled {
                if progress.isCancelled {
                    gate.cancel()
                    return
                }
                try? await Task.sleep(for: cancellationPollInterval)
            }
        }
        defer { watcher.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    process.terminationHandler = { finished in
                        /// Closing the handle is part of compressing, not cleanup after it: a
                        /// volume that reports a deferred write failure does so here, and the plain
                        /// writer propagates its own close error. Swallowed, a truncated temp would
                        /// have replaced a valid dump on a gzip that exited zero.
                        let closeError: (any Error)?
                        do {
                            try handle.close()
                            closeError = nil
                        } catch {
                            closeError = error
                        }
                        guard finished.terminationStatus == 0 else {
                            continuation.resume(throwing: failure(
                                status: finished.terminationStatus, from: errorPipe))
                            return
                        }
                        if let closeError {
                            continuation.resume(throwing: closeError)
                            return
                        }
                        continuation.resume()
                    }
                    do {
                        try gate.launch(process)
                    } catch {
                        try? handle.close()
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                gate.cancel()
            }
        } catch {
            /// A Stop killed the process, so gzip's own non-zero exit is what surfaced. The user
            /// asked to stop, not for a compression error.
            guard !progress.isCancelled else { throw PluginExportCancellationError() }
            throw error
        }

        /// A Stop landing between gzip's exit and here still abandons the file. Reporting an export
        /// the user asked to stop as finished is the worse answer, and nothing has been published.
        try progress.checkCancellation()
    }

    private static func failure(status: Int32, from errorPipe: Pipe) -> any Error {
        let text = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return PluginExportError.exportFailed(String(
                format: String(localized: "Compression failed with exit status %lld"), Int64(status)))
        }
        return PluginExportError.exportFailed(String(
            format: String(localized: "Compression failed with exit status %1$lld: %2$@"),
            Int64(status), text))
    }

    /// `Process.terminate()` on a process that was never launched raises an uncaught
    /// `NSInvalidArgumentException` ("task not launched"), so a cancel that arrives before the
    /// launch has to stop it rather than race it. The lock is held across `run()` for that, and
    /// released before `terminate()` so nothing the kill wakes can deadlock against it.
    private final class ProcessGate: @unchecked Sendable {
        private let lock = NSLock()
        private var launched: Process?
        private var cancelled = false

        internal func launch(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw PluginExportCancellationError() }
            try process.run()
            launched = process
        }

        internal func cancel() {
            lock.lock()
            cancelled = true
            let running = launched
            lock.unlock()
            running?.terminate()
        }
    }
}

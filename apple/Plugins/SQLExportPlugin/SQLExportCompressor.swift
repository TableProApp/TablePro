//
//  SQLExportCompressor.swift
//  SQLExportPlugin
//

import Foundation
import TableProPluginKit
import TableProProcess

// Compresses through the atomic pair, so a failed or stopped compression leaves the previous file whole (#2533).
internal enum SQLExportCompressor {
    private static let gzipPath = "/usr/bin/gzip"

    // Stop calls `Progress.cancel()`, not a task cancellation, so it is polled.
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
        let process: Process
        do {
            // Apple's gzip reads extra options from GZIP.
            process = try ProcessLauncher.process(for: ProcessCommand(
                executable: URL(fileURLWithPath: gzipPath),
                arguments: ["-c", source.standardizedFileURL.path(percentEncoded: false)],
                environment: ProcessEnvironment.minimal()
            ))
        } catch {
            try? handle.close()
            throw error
        }
        let errorPipe = Pipe()
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
                        // A volume can report a deferred write failure only at close, and a swallowed one
                        // would let a truncated temp replace a valid dump.
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
            // A Stop kills gzip, so its non-zero exit means the user stopped, not that compression failed.
            guard !progress.isCancelled else { throw PluginExportCancellationError() }
            throw error
        }

        // A Stop that lands after gzip exits still abandons the file.
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

    // `terminate()` on a process never launched raises an uncaught exception, so the lock spans `run()`
    // and is released before `terminate()`.
    private final class ProcessGate: @unchecked Sendable {
        private let lock = NSLock()
        private var launched: Process?
        private var cancelled = false

        func launch(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw PluginExportCancellationError() }
            try process.run()
            launched = process
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = launched
            lock.unlock()
            running?.terminate()
        }
    }
}

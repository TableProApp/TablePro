//
//  SQLExportPartOutput.swift
//  SQLExportPlugin
//

import Foundation
import TableProGzip

/// Where one part of a dump goes: the file as written, or a gzip stream over it.
nonisolated internal protocol SQLExportPartOutput: AnyObject {
    func write(_ data: Data) throws

    /// Whether the part, closed after `extra` more bytes, could be larger than `cap` bytes on disk.
    func wouldExceed(_ cap: Int, adding extra: Int) throws -> Bool

    /// Writes what the part still owes and closes the file. A volume can report a deferred write
    /// failure only at close, so it throws rather than letting a truncated part be published.
    func close() throws

    /// Closes the file without finishing it, for a part that will be removed.
    func abandon()
}

nonisolated internal final class SQLExportPlainOutput: SQLExportPartOutput {
    private let handle: FileHandle
    private var written = 0

    internal init(handle: FileHandle) {
        self.handle = handle
    }

    internal func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        written += data.count
    }

    internal func wouldExceed(_ cap: Int, adding extra: Int) throws -> Bool {
        written + extra > cap
    }

    internal func close() throws {
        try handle.close()
    }

    internal func abandon() {
        try? handle.close()
    }
}

/// Deflates on a serial queue of its own, so compression overlaps reading the next rows instead of
/// following the whole dump. The queue holds at most `maxChunksInFlight` chunks; a writer that gets
/// ahead of it waits, which keeps memory bounded by a few chunks whatever the dump's size.
///
/// The size of a part on disk is known exactly only up to the last sync flush. A splitting writer
/// flushes every `syncInterval` input bytes, so the bound it rotates on is at most that far above
/// the truth, and it drains the queue before deciding a part is full.
///
/// Unchecked: the writer's state is touched only by the one caller, the deflater and the handle
/// only on the serial queue, and what both read is behind the lock.
nonisolated internal final class SQLExportGzipOutput: SQLExportPartOutput, @unchecked Sendable {
    private struct Progress {
        var compressedBytes = 0
        var syncedInputBytes = 0
        var compressedBytesAtSync = 0
        var failure: (any Error)?
    }

    private static let chunkSize = 1 << 20
    private static let maxChunksInFlight = 2

    private let handle: FileHandle
    private let deflater: GzipDeflater
    private let queue = DispatchQueue(label: "com.TablePro.SQLExport.gzip", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: maxChunksInFlight)
    private let progressLock = NSLock()
    private var progressState = Progress()
    private let syncInterval: Int?

    private var buffer = Data()
    private var acceptedInputBytes = 0
    private var inputBytesAtLastSync = 0

    /// `splitSizeBytes` above zero turns on the periodic sync flush a size cap needs.
    internal init(handle: FileHandle, splitSizeBytes: Int) throws {
        self.handle = handle
        self.deflater = try GzipDeflater(container: .gzip)
        self.syncInterval = splitSizeBytes > 0 ? min(Self.chunkSize, max(splitSizeBytes / 32, 16 * 1_024)) : nil
        buffer.reserveCapacity(Self.chunkSize)
    }

    internal func write(_ data: Data) throws {
        try rethrowFailure()
        buffer.append(data)
        acceptedInputBytes += data.count
        if let syncInterval, acceptedInputBytes - inputBytesAtLastSync >= syncInterval {
            submit(flushing: true)
        } else if buffer.count >= Self.chunkSize {
            submit(flushing: false)
        }
    }

    internal func wouldExceed(_ cap: Int, adding extra: Int) throws -> Bool {
        try rethrowFailure()
        if bound(adding: extra) <= cap { return false }
        // The quick bound counts every byte since the last sync as incompressible; flush to know.
        submit(flushing: true)
        queue.sync {}
        try rethrowFailure()
        return bound(adding: extra) > cap
    }

    internal func close() throws {
        submit(flushing: false)
        queue.sync {
            guard withProgress({ $0.failure == nil }) else { return }
            do {
                try deflater.finish { try handle.write(contentsOf: $0) }
            } catch {
                withProgress { $0.failure = error }
            }
        }
        if let failure = withProgress({ $0.failure }) {
            try? handle.close()
            throw failure
        }
        try handle.close()
    }

    internal func abandon() {
        queue.sync {}
        try? handle.close()
    }

    // zlib's worst case for incompressible input is a stored block of 5 bytes per 16 KiB; the
    // constant covers the final block and the 8-byte trailer.
    private static func compressedBound(_ input: Int) -> Int {
        input + (input >> 11) + 64
    }

    private func bound(adding extra: Int) -> Int {
        let synced = withProgress { (bytes: $0.compressedBytesAtSync, input: $0.syncedInputBytes) }
        return synced.bytes + Self.compressedBound(acceptedInputBytes - synced.input + extra)
    }

    private func submit(flushing: Bool) {
        guard !buffer.isEmpty || flushing else { return }
        let chunk = buffer
        buffer = Data()
        buffer.reserveCapacity(Self.chunkSize)
        let inputThrough = acceptedInputBytes
        if flushing { inputBytesAtLastSync = inputThrough }
        // Backpressure: the queue is a dispatch queue, not the cooperative pool, so it always frees a slot.
        slots.wait()
        queue.async { [self] in
            defer { slots.signal() }
            deflate(chunk, flushing: flushing, inputThrough: inputThrough)
        }
    }

    // Runs on `queue` only.
    private func deflate(_ chunk: Data, flushing: Bool, inputThrough: Int) {
        guard withProgress({ $0.failure == nil }) else { return }
        do {
            var produced = 0
            let sink: (UnsafeRawBufferPointer) throws -> Void = { [handle] bytes in
                try handle.write(contentsOf: bytes)
                produced += bytes.count
            }
            try chunk.withUnsafeBytes { try deflater.deflate($0, into: sink) }
            if flushing { try deflater.flush(into: sink) }
            let written = produced
            withProgress { state in
                state.compressedBytes += written
                if flushing {
                    state.syncedInputBytes = inputThrough
                    state.compressedBytesAtSync = state.compressedBytes
                }
            }
        } catch {
            withProgress { $0.failure = error }
        }
    }

    private func withProgress<T>(_ body: (inout Progress) -> T) -> T {
        progressLock.lock()
        defer { progressLock.unlock() }
        return body(&progressState)
    }

    private func rethrowFailure() throws {
        if let failure = withProgress({ $0.failure }) { throw failure }
    }
}

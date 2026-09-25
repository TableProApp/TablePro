//
//  PipeReader.swift
//  TablePro
//

import Foundation
import os

/// Hands a pipe's output to a consumer as it arrives, one chunk at a time and in order.
///
/// Clearing `readabilityHandler` does not recall a callback Foundation has already dispatched, so
/// that callback can run its read after the owner has drained the pipe or closed it. Every read
/// here happens under one lock and only while a consumer is installed, and both ways of stopping
/// remove the consumer under that lock, so once either returns nothing is reading the descriptor
/// and nothing will. The handle can be closed straight after.
final class PipeReader: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PipeReader")

    private let handle: FileHandle
    private let descriptor: Int32
    private let lock = NSLock()
    private var consumer: (@Sendable (Data) -> Void)?

    init(_ handle: FileHandle) {
        self.handle = handle
        descriptor = handle.fileDescriptor
    }

    func start(delivering consumer: @escaping @Sendable (Data) -> Void) {
        lock.withLock { self.consumer = consumer }
        handle.readabilityHandler = { _ in
            self.readArrivedBytes()
        }
    }

    /// Stops reading, first handing the consumer what the pipe already holds, up to `limit` bytes.
    /// It never waits on a writer, because a helper that inherited the write end can hold it open
    /// for as long as it lives.
    func stop(drainingUpTo limit: Int = 0) {
        stopReading { consumer in
            var taken = 0
            while taken < limit, DescriptorRead.hasInputWithoutWaiting(descriptor) {
                let wanted = min(DescriptorRead.pipeCapacity, limit - taken)
                guard let chunk = try? DescriptorRead.availableBytes(from: descriptor, upTo: wanted),
                      !chunk.isEmpty else { return }
                taken += chunk.count
                consumer(chunk)
            }
        }
    }

    /// Stops reading once every writer has closed the pipe, handing the consumer everything written
    /// before that. A helper that inherited the write end keeps this waiting for as long as it lives.
    func stopAtEndOfFile() {
        stopReading { consumer in
            while let chunk = try? DescriptorRead.availableBytes(from: descriptor), !chunk.isEmpty {
                consumer(chunk)
            }
        }
    }

    private func stopReading(thenDrainInto drain: (@Sendable (Data) -> Void) -> Void) {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        guard let consumer else { return }
        self.consumer = nil
        drain(consumer)
    }

    private func readArrivedBytes() {
        lock.lock()
        defer { lock.unlock() }
        guard let consumer else { return }
        do {
            let chunk = try DescriptorRead.availableBytes(from: descriptor)
            guard !chunk.isEmpty else {
                endReading()
                return
            }
            consumer(chunk)
        } catch POSIXError.EAGAIN {
            return
        } catch {
            Self.logger.error("Reading a pipe failed: \(error.publicLogShape, privacy: .public)")
            endReading()
        }
    }

    private func endReading() {
        consumer = nil
        handle.readabilityHandler = nil
    }
}

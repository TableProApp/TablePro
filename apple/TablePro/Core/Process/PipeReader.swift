//
//  PipeReader.swift
//  TablePro
//

import Foundation
import os
import TableProUtilities

internal final class PipeReader: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PipeReader")

    private let handle: FileHandle
    private let descriptor: Int32
    private let lock = NSLock()
    private var consumer: (@Sendable (Data) -> Void)?
    private var onEnd: (@Sendable () -> Void)?

    init(_ handle: FileHandle) {
        self.handle = handle
        descriptor = handle.fileDescriptor
    }

    // onEnd runs once when the pipe reaches end of file or fails, never after a stop.
    func start(
        delivering consumer: @escaping @Sendable (Data) -> Void,
        onEnd: (@Sendable () -> Void)? = nil
    ) {
        lock.withLock {
            self.consumer = consumer
            self.onEnd = onEnd
        }
        handle.readabilityHandler = { _ in
            self.readArrivedBytes()
        }
    }

    func startDeliveringLines(
        _ deliver: @escaping @Sendable (String) -> Void,
        onEnd: @escaping @Sendable () -> Void = {}
    ) {
        let splitter = OSAllocatedUnfairLock(initialState: PipeLineSplitter())
        start(
            delivering: { chunk in
                for line in splitter.withLock({ $0.lines(appending: chunk) }) {
                    deliver(line)
                }
            },
            onEnd: {
                if let last = splitter.withLock({ $0.finish() }) {
                    deliver(last)
                }
                onEnd()
            }
        )
    }

    func stop(drainingUpTo limit: Int = 0) {
        stopReading { consumer in
            let buffered = DescriptorRead.bufferedBytes(from: descriptor, upTo: limit)
            guard !buffered.isEmpty else { return }
            consumer(buffered)
        }
    }

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
        onEnd = nil
        drain(consumer)
    }

    private func readArrivedBytes() {
        lock.lock()
        let ended = readLocked()
        lock.unlock()
        // Outside the lock: the callback may stop this reader.
        ended?()
    }

    private func readLocked() -> (@Sendable () -> Void)? {
        guard let consumer else { return nil }
        do {
            let chunk = try DescriptorRead.availableBytes(from: descriptor)
            guard !chunk.isEmpty else { return endReading() }
            consumer(chunk)
            return nil
        } catch POSIXError.EAGAIN {
            return nil
        } catch {
            Self.logger.error("Reading a pipe failed: \(error.publicLogShape, privacy: .public)")
            return endReading()
        }
    }

    private func endReading() -> (@Sendable () -> Void)? {
        consumer = nil
        handle.readabilityHandler = nil
        defer { onEnd = nil }
        return onEnd
    }
}

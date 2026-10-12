//
//  PipeReader.swift
//  TablePro
//

import Foundation
import os

internal final class PipeReader: @unchecked Sendable {
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

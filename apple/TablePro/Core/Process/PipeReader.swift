//
//  PipeReader.swift
//  TablePro
//

import Foundation
import os
import TableProProcess

internal final class PipeReader: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PipeReader")

    private let handle: FileHandle
    private let descriptor: Int32
    // Recursive: an owner may stop the reader from inside its own consumer or end callback.
    private let lock = NSRecursiveLock()
    private var consumer: (@Sendable (Data) -> Void)?
    private var atEnd: (@Sendable ((any Error)?) -> Void)?

    init(_ handle: FileHandle) {
        self.handle = handle
        descriptor = handle.fileDescriptor
    }

    // `atEnd` gets nil at end of file or the read error, after the last chunk, and never once the owner stopped the reader.
    func start(
        delivering consumer: @escaping @Sendable (Data) -> Void,
        atEnd: (@Sendable ((any Error)?) -> Void)? = nil
    ) {
        lock.withLock {
            self.consumer = consumer
            self.atEnd = atEnd
        }
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
        atEnd = nil
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
                endReading(failure: nil)
                return
            }
            consumer(chunk)
        } catch POSIXError.EAGAIN {
            return
        } catch {
            Self.logger.error("Reading a pipe failed: \(error.publicLogShape, privacy: .public)")
            endReading(failure: error)
        }
    }

    private func endReading(failure: (any Error)?) {
        consumer = nil
        handle.readabilityHandler = nil
        let finished = atEnd
        atEnd = nil
        finished?(failure)
    }
}

//
//  DescriptorRead.swift
//  TablePro
//

import Darwin
import Foundation

/// Reads a descriptor with `read(2)` and reports a failed read as a thrown `POSIXError`.
///
/// `FileHandle.availableData` raises `NSFileHandleOperationException` on any failed read, and an
/// Objective-C exception unwinding through Swift ends the process. `FileHandle.read(upToCount:)`
/// throws instead, but on a pipe it waits for the whole count or for every writer to close, and on
/// a non-blocking pipe it throws away the bytes it read before `EAGAIN`, so it cannot return
/// whatever has arrived so far.
enum DescriptorRead {
    /// The most a macOS pipe holds, so a writer that has exited cannot have left more than this.
    static let pipeCapacity = 65_536

    /// The bytes one read returns, at most `limit`, empty at end of file.
    static func availableBytes(from descriptor: Int32, upTo limit: Int = pipeCapacity) throws -> Data {
        var bytes = Data(count: limit)
        let received = try bytes.withUnsafeMutableBytes { buffer in
            try read(descriptor, into: buffer)
        }
        bytes.count = received
        return bytes
    }

    /// Whether a read would return at once, with bytes or at end of file, instead of waiting on a
    /// writer. Asks `poll(2)` rather than setting `O_NONBLOCK`, which would change the descriptor for
    /// every other reader of it too.
    static func hasInputWithoutWaiting(_ descriptor: Int32) -> Bool {
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&request, 1, 0) > 0 else { return false }
        return request.revents & Int16(POLLIN | POLLHUP) != 0
    }

    private static func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        while true {
            let received = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            if received >= 0 {
                return received
            }
            let failure = errno
            guard failure == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
        }
    }
}

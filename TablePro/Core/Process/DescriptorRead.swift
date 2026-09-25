//
//  DescriptorRead.swift
//  TablePro
//

import Darwin
import Foundation

internal enum DescriptorRead {
    static let pipeCapacity = 65_536

    static func availableBytes(from descriptor: Int32, upTo limit: Int = pipeCapacity) throws -> Data {
        var bytes = Data(count: limit)
        let received = try bytes.withUnsafeMutableBytes { buffer in
            try read(descriptor, into: buffer)
        }
        bytes.count = received
        return bytes
    }

    static func nextBytes(from descriptor: Int32, upTo limit: Int = pipeCapacity) throws -> Data {
        while true {
            do {
                return try availableBytes(from: descriptor, upTo: limit)
            } catch POSIXError.EAGAIN {
                try waitForInput(descriptor)
            }
        }
    }

    static func bufferedBytes(from descriptor: Int32, upTo limit: Int) -> Data {
        var buffered = Data()
        while buffered.count < limit, hasInputWithoutWaiting(descriptor) {
            let wanted = min(pipeCapacity, limit - buffered.count)
            guard let chunk = try? availableBytes(from: descriptor, upTo: wanted), !chunk.isEmpty else { break }
            buffered.append(chunk)
        }
        return buffered
    }

    static func hasInputWithoutWaiting(_ descriptor: Int32) -> Bool {
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&request, 1, 0) > 0 else { return false }
        return request.revents & Int16(POLLIN | POLLHUP) != 0
    }

    private static func waitForInput(_ descriptor: Int32) throws {
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while poll(&request, 1, -1) == -1 {
            try throwUnlessInterrupted(errno)
        }
    }

    private static func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        while true {
            let received = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            if received >= 0 {
                return received
            }
            try throwUnlessInterrupted(errno)
        }
    }

    private static func throwUnlessInterrupted(_ failure: Int32) throws {
        guard failure == EINTR else {
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }
}

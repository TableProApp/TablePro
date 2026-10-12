import Darwin
import Foundation

enum HanaHelperPipeRead: Equatable, Sendable {
    case complete(Data)
    case endOfStream(receivedByteCount: Int)
}

enum HanaHelperPipe {
    static let maximumChunkByteCount = 16 << 20

    static func suppressBrokenPipeSignal(on descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let chunk = min(buffer.count - offset, maximumChunkByteCount)
                let written = Darwin.write(descriptor, start + offset, chunk)
                if written >= 0 {
                    offset += written
                    continue
                }
                try throwUnlessInterrupted(errno)
            }
        }
    }

    static func read(exactly count: Int, from descriptor: Int32) throws -> HanaHelperPipeRead {
        guard count > 0 else { return .complete(Data()) }
        let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: min(count, maximumChunkByteCount), alignment: 1)
        defer { chunk.deallocate() }
        guard let start = chunk.baseAddress else { return .endOfStream(receivedByteCount: 0) }
        var bytes = Data()
        while bytes.count < count {
            let received = Darwin.read(descriptor, start, min(count - bytes.count, chunk.count))
            if received > 0 {
                bytes.append(start.assumingMemoryBound(to: UInt8.self), count: received)
                continue
            }
            if received == 0 {
                return .endOfStream(receivedByteCount: bytes.count)
            }
            try throwUnlessInterrupted(errno)
        }
        return .complete(bytes)
    }

    private static func throwUnlessInterrupted(_ failure: Int32) throws {
        guard failure == EINTR else {
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }
}

import Darwin
import Foundation

public enum TeradataWireError: Error, CustomStringConvertible, LocalizedError {
    case connectionFailed(String)
    case truncated(String)
    case malformed(String)
    case server(code: Int, message: String)
    case unsupported(String)
    case cancelled

    public var description: String {
        switch self {
        case .connectionFailed(let detail): return "connection failed: \(detail)"
        case .truncated(let what): return "truncated: \(what)"
        case .malformed(let what): return "malformed: \(what)"
        case .server(let code, let message): return "\(message) (\(code))"
        case .unsupported(let what): return "unsupported: \(what)"
        case .cancelled: return "cancelled"
        }
    }

    public var errorDescription: String? { description }
}

protocol TeradataTransport: AnyObject {
    func send(_ bytes: [UInt8]) throws
    func receive(_ count: Int) throws -> [UInt8]
    func cancel()
    func close()
}

final class TeradataSocket: TeradataTransport {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var closed = false

    init(host: String, port: UInt16, timeoutSeconds: Int) throws {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0, let head = resolved else {
            throw TeradataWireError.connectionFailed("cannot resolve \(host)")
        }
        defer { freeaddrinfo(resolved) }

        var lastErrno: Int32 = 0
        var candidate: UnsafeMutablePointer<addrinfo>? = head
        while let node = candidate {
            let handle = socket(node.pointee.ai_family, node.pointee.ai_socktype, node.pointee.ai_protocol)
            if handle >= 0 {
                if connect(handle, node.pointee.ai_addr, node.pointee.ai_addrlen) == 0 {
                    descriptor = handle
                    break
                }
                lastErrno = errno
                Darwin.close(handle)
            } else {
                lastErrno = errno
            }
            candidate = node.pointee.ai_next
        }
        guard descriptor >= 0 else {
            throw TeradataWireError.connectionFailed("connect \(host):\(port) errno \(lastErrno)")
        }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR) }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func send(_ bytes: [UInt8]) throws {
        if isClosed { throw TeradataWireError.cancelled }
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let written = Darwin.send(descriptor, raw.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if written <= 0 {
                    if isClosed { throw TeradataWireError.cancelled }
                    throw TeradataWireError.truncated("send errno \(errno)")
                }
                offset += written
            }
        }
    }

    func receive(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        try buffer.withUnsafeMutableBytes { raw in
            while offset < count {
                let read = Darwin.recv(descriptor, raw.baseAddress!.advanced(by: offset), count - offset, 0)
                if read == 0 {
                    if isClosed { throw TeradataWireError.cancelled }
                    throw TeradataWireError.truncated("peer closed after \(offset)/\(count)")
                }
                if read < 0 {
                    if isClosed { throw TeradataWireError.cancelled }
                    throw TeradataWireError.truncated("recv errno \(errno)")
                }
                offset += read
            }
        }
        return buffer
    }
}

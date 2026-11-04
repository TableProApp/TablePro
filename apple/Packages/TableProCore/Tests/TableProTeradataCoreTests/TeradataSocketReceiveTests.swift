import Darwin
import Dispatch
@testable import TableProTeradataCore
import Testing

private struct LoopbackFailure: Error {
    let step: String
    let code: Int32
}

private struct LoopbackListener {
    let descriptor: Int32
    let port: UInt16

    init() throws {
        let handle = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard handle >= 0 else { throw LoopbackFailure(step: "socket", code: errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(handle, generic, length) == 0 && listen(handle, 1) == 0 && getsockname(handle, generic, &length) == 0
            }
        }
        guard listening else {
            let code = errno
            Darwin.close(handle)
            throw LoopbackFailure(step: "listen", code: code)
        }
        descriptor = handle
        port = UInt16(bigEndian: address.sin_port)
    }

    func acceptPeer() throws -> Int32 {
        let peer = accept(descriptor, nil, nil)
        guard peer >= 0 else { throw LoopbackFailure(step: "accept", code: errno) }
        var one: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return peer
    }
}

private func writeAll(_ bytes: [UInt8], to descriptor: Int32) {
    bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
            if written <= 0 { return }
            offset += written
        }
    }
}

struct TeradataSocketReceiveTests {
    private static func connect(to listener: LoopbackListener) throws -> TeradataSocket {
        try TeradataSocket(host: "127.0.0.1", port: listener.port, deadline: TeradataConnectDeadline(milliseconds: 5_000))
    }

    @Test("A reply longer than one read chunk arrives whole and in order")
    func longReplyArrivesWhole() throws {
        let listener = try LoopbackListener()
        defer { Darwin.close(listener.descriptor) }
        let socket = try Self.connect(to: listener)
        defer { socket.close() }
        let peer = try listener.acceptPeer()
        let reply = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        DispatchQueue.global().async {
            writeAll(reply, to: peer)
            Darwin.close(peer)
        }

        let header = try socket.receive(52)
        let body = try socket.receive(reply.count - 52)
        #expect(header + body == reply)
    }

    @Test("A length far past what the peer sent fails when it closes, without allocating the claimed size")
    func claimedLengthIsNotAllocatedUpFront() throws {
        let listener = try LoopbackListener()
        defer { Darwin.close(listener.descriptor) }
        let socket = try Self.connect(to: listener)
        defer { socket.close() }
        let peer = try listener.acceptPeer()
        writeAll([0x01, 0x02, 0x03], to: peer)
        Darwin.close(peer)

        #expect(throws: TeradataWireError.self) { try socket.receive(.max) }
    }
}

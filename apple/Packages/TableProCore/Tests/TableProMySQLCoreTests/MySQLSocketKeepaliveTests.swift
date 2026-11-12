import Darwin
import Foundation
import TableProMySQLCore
import Testing

struct MySQLSocketKeepaliveTests {
    @Test("A TCP socket probes a silent peer after 60 s idle, every 10 s, and gives up after 3")
    func tcpSocketTakesTheValues() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(socket >= 0)
        defer { close(socket) }

        #expect(MySQLSocketKeepalive.enable(on: socket))
        #expect(Self.intOption(socket, SOL_SOCKET, SO_KEEPALIVE) != 0)
        #expect(Self.intOption(socket, IPPROTO_TCP, TCP_KEEPALIVE) == 60)
        #expect(Self.intOption(socket, IPPROTO_TCP, TCP_KEEPINTVL) == 10)
        #expect(Self.intOption(socket, IPPROTO_TCP, TCP_KEEPCNT) == 3)
    }

    @Test("A dead peer fails about 90 s after the last traffic")
    func deadPeerBound() {
        let seconds = MySQLSocketKeepalive.idleSeconds + MySQLSocketKeepalive.intervalSeconds * MySQLSocketKeepalive.probeCount
        #expect(seconds == 90)
    }

    @Test("A socket that is not TCP reports that the keepalive could not be set")
    func localSocketRefuses() throws {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(socket >= 0)
        defer { close(socket) }

        #expect(!MySQLSocketKeepalive.enable(on: socket))
    }

    private static func intOption(_ socket: Int32, _ level: Int32, _ name: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(socket, level, name, &value, &length)
        return value
    }
}
